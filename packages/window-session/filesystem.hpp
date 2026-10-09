#pragma once
#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>
extern "C" {
#include <lua.h>
}

namespace SessionFiles {
namespace fs = std::filesystem;
inline fs::path path(lua_State* L) {
    if (lua_type(L, 1) != LUA_TSTRING) throw std::runtime_error("Expected filesystem path");
    size_t size = 0;
    const char* value = lua_tolstring(L, 1, &size);
    const std::string text(value, size);
    if (text.empty() || text.find('\0') != std::string::npos || !fs::path(text).is_absolute())
        throw std::runtime_error("Expected absolute path without NUL bytes");
    return text;
}
inline int failure(lua_State* L, const std::exception& error) {
    lua_pushnil(L);
    lua_pushstring(L, error.what());
    return 2;
}
inline fs::path state_directory() {
    std::string base;
    if (const auto value = getenv("XDG_STATE_HOME")) base = value;
    else {
        const auto home = getenv("HOME");
        if (!home) throw std::runtime_error("HOME is required for session state");
        base = std::string(home) + "/.local/state";
    }
    const fs::path dir(base + "/hyprcachy/window-session");
    if (!dir.is_absolute()) throw std::runtime_error("Session state directory must be absolute");
    return dir;
}
inline void prepare_directory(const fs::path& dir) {
    fs::create_directories(dir);
    if (!fs::is_directory(fs::symlink_status(dir)))
        throw std::runtime_error("State directory must be a real directory, not a symlink");
    fs::permissions(dir, fs::perms::owner_all, fs::perm_options::replace);
}
inline int archive_snapshot(lua_State* L) {
    try {
        const auto file = path(L);
        if (!fs::is_regular_file(fs::symlink_status(file)))
            throw std::runtime_error("Snapshot must be a regular file, not a symlink");
        auto archive = file.string() + ".incompatible-XXXXXX";
        const int fd = mkstemp(archive.data()); // Reserve a unique name; never replace an existing backup.
        if (fd < 0) throw std::runtime_error("Cannot reserve snapshot archive");
        close(fd);
        std::error_code error;
        fs::rename(file, archive, error);
        if (error) {
            std::error_code ignored;
            fs::remove(archive, ignored);
            throw std::runtime_error("Cannot archive snapshot: " + error.message());
        }
        lua_pushlstring(L, archive.data(), archive.size());
        return 1;
    } catch (const std::exception& error) { return failure(L, error); }
}
inline int process_command(lua_State* L) {
    try {
        if (!lua_isinteger(L, 1)) throw std::runtime_error("Invalid window PID");
        const auto pid = lua_tointeger(L, 1);
        if (pid <= 0 || pid > INT_MAX) throw std::runtime_error("Invalid window PID");
        struct File {
            int fd;
            ~File() { if (fd >= 0) close(fd); }
        };
        const auto path = "/proc/" + std::to_string(pid);
        const File process{open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
        struct stat owner{};
        if (process.fd < 0 || fstat(process.fd, &owner) || owner.st_uid != geteuid())
            throw std::runtime_error("Window process is unavailable or owned by another user");
        const auto link = [&](const char* name) {
            std::array<char, 4096> buffer;
            const auto size = readlinkat(process.fd, name, buffer.data(), buffer.size());
            if (size <= 0 || static_cast<size_t>(size) >= buffer.size())
                throw std::runtime_error("Cannot read process executable or working directory");
            std::string value(buffer.data(), size);
            if (value.front() != '/' || value.ends_with(" (deleted)"))
                throw std::runtime_error("Process path is not available for relaunch");
            return value;
        };
        const auto exe = link("exe"), cwd = link("cwd");
        // GNU env interprets '=' as an assignment even after '--'.
        if (exe.contains('=')) throw std::runtime_error("Unsupported executable path");
        const File command{openat(process.fd, "cmdline", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
        if (command.fd < 0) throw std::runtime_error("Cannot read process arguments");
        std::array<char, 65537> buffer;
        size_t size = 0;
        while (size < buffer.size()) {
            const auto n = read(command.fd, buffer.data() + size, buffer.size() - size);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) throw std::runtime_error("Cannot read process arguments");
            if (n == 0) break;
            size += n;
        }
        if (!size || size + exe.size() + cwd.size() > 65536 || buffer[size - 1] != '\0')
            throw std::runtime_error("Process command is empty or exceeds 64 KiB");
        std::vector<std::string> args;
        for (size_t pos = 0; pos < size;) {
            args.emplace_back(buffer.data() + pos);
            pos += args.back().size() + 1;
            if (args.size() > 256) throw std::runtime_error("Process command exceeds 256 arguments");
        }
        if (args.front().empty() || exe != link("exe") || cwd != link("cwd")
            || fstat(process.fd, &owner) || owner.st_uid != geteuid())
            throw std::runtime_error("Process changed while capturing command");
        lua_newtable(L);
        lua_pushlstring(L, exe.data(), exe.size());
        lua_setfield(L, -2, "exe");
        lua_pushlstring(L, cwd.data(), cwd.size());
        lua_setfield(L, -2, "cwd");
        lua_newtable(L);
        for (size_t i = 0; i < args.size(); ++i) {
            lua_pushlstring(L, args[i].data(), args[i].size());
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "argv");
        return 1;
    } catch (const std::exception& error) { return failure(L, error); }
}
inline int desktop_files(lua_State* L) {
    try {
        const auto dir = path(L);
        std::vector<std::string> files;
        if (fs::exists(dir)) {
            for (const auto& entry : fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied)) {
                if (entry.path().extension() == ".desktop" && (entry.is_symlink() || entry.is_regular_file()))
                    files.push_back(entry.path().string());
            }
        }
        std::sort(files.begin(), files.end());
        lua_newtable(L);
        lua_Integer index = 0;
        for (const auto& file : files) {
            lua_pushlstring(L, file.data(), file.size());
            lua_rawseti(L, -2, ++index);
        }
        return 1;
    } catch (const std::exception& error) { return failure(L, error); }
}
}
