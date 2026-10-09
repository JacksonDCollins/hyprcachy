#pragma once
#include <array>
#include <cerrno>
#include <charconv>
#include <fcntl.h>
#include <map>
#include <sstream>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

// Protocol-owned capabilities and initial configure sizes. Full desktop layout
// remains in the controller's snapshot; neither store contains browser tabs.
namespace SessionProtocol {
inline void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
inline std::string hex(const std::string& value) {
    constexpr char digits[] = "0123456789abcdef";
    std::string out;
    for (unsigned char c : value) { out += digits[c >> 4]; out += digits[c & 15]; }
    return out;
}
inline bool hexadecimal(const std::string& value) {
    return value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
inline std::string token() {
    std::array<char, 32> bytes;
    size_t pos = 0;
    while (pos < bytes.size()) {
        const auto n = getrandom(bytes.data() + pos, bytes.size() - pos, 0);
        if (n < 0 && errno == EINTR) continue;
        require(n > 0, "Cannot generate a session capability");
        pos += n;
    }
    return hex(std::string(bytes.data(), bytes.size()));
}
struct Size {
    int width = 0, height = 0;
    bool operator==(const Size&) const = default;
};
struct Window {
    Size size;
    std::string identity;
    bool operator==(const Window&) const = default;
};
struct Store {
    static constexpr size_t maxSessions = 128, maxWindows = 256, maxBytes = 524288;
    using Windows = std::map<std::string, Window>; // Hex-encoded, bounded client names.
    std::map<std::string, Windows> sessions;
    int directory = -1;
    bool healthy = true;

    explicit Store(const std::string& path) {
        directory = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat st{};
        if (directory < 0 || fstat(directory, &st) || st.st_uid != geteuid() || (st.st_mode & 077)) {
            if (directory >= 0) close(directory);
            throw std::runtime_error("Session protocol requires an owned private directory");
        }
        try { load(); } catch (...) { close(directory); directory = -1; throw; }
    }
    ~Store() { if (directory >= 0) close(directory); }
    Store(const Store&) = delete;
    Store& operator=(const Store&) = delete;

    static void validate(const std::map<std::string, Windows>& data) {
        require(data.size() <= maxSessions, "Too many protocol sessions");
        size_t windows = 0;
        std::set<std::string> identities;
        for (const auto& [id, names] : data) {
            require(id.size() == 64 && hexadecimal(id), "Invalid session capability");
            windows += names.size();
            for (const auto& [name, window] : names)
                require(name.size() <= 1024 && name.size() % 2 == 0 && hexadecimal(name)
                            && window.identity.size() == 64 && hexadecimal(window.identity)
                            && identities.insert(id + "/" + window.identity).second
                            && window.size.width >= 0 && window.size.height >= 0
                            && window.size.width <= 1048576 && window.size.height <= 1048576,
                        "Invalid protocol window state");
        }
        require(windows <= maxWindows, "Too many protocol windows");
    }
    void load() {
        const int fd = openat(directory, "protocol.tsv", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0 && errno == ENOENT) return;
        require(fd >= 0, "Cannot open protocol state");
        std::string text;
        try {
            struct stat st{};
            require(!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == geteuid()
                        && !(st.st_mode & 077) && st.st_size <= static_cast<off_t>(maxBytes), "Unsafe protocol state file");
            std::array<char, 4096> buffer;
            for (;;) {
                const auto n = read(fd, buffer.data(), buffer.size());
                if (n < 0 && errno == EINTR) continue;
                require(n >= 0, "Cannot read protocol state");
                if (!n) break;
                text.append(buffer.data(), n);
                require(text.size() <= maxBytes, "Protocol state exceeds size limit");
            }
        } catch (...) { close(fd); throw; }
        close(fd);
        require(!text.empty() && text.back() == '\n', "Truncated protocol state");
        std::istringstream input(text);
        std::string line, id;
        require(bool(std::getline(input, line)) && line == "hyprcachy-protocol-v1", "Invalid protocol state header");
        std::map<std::string, Windows> next;
        while (std::getline(input, line)) {
            require(line.size() <= 1200, "Protocol state line exceeds limit");
            if (line.starts_with("S\t")) {
                id = line.substr(2);
                require(next.emplace(id, Windows{}).second, "Duplicate protocol session");
            } else {
                const auto a = line.find('\t'), b = a == std::string::npos ? a : line.find('\t', a + 1);
                const auto c = b == std::string::npos ? b : line.find('\t', b + 1);
                require(!id.empty() && a != std::string::npos && b != std::string::npos && c != std::string::npos, "Malformed protocol window");
                Window window;
                window.identity = line.substr(a + 1, b - a - 1);
                auto number = [&](size_t first, size_t last, int& value) {
                    auto [end, error] = std::from_chars(line.data() + first, line.data() + last, value);
                    require(error == std::errc{} && end == line.data() + last, "Invalid protocol size");
                };
                number(b + 1, c, window.size.width); number(c + 1, line.size(), window.size.height);
                require(next.at(id).emplace(line.substr(0, a), window).second, "Duplicate protocol window");
            }
            validate(next);
        }
        sessions = std::move(next);
    }
    void save() {
        require(healthy, "Protocol storage is unavailable");
        validate(sessions);
        std::string text = "hyprcachy-protocol-v1\n";
        for (const auto& [id, windows] : sessions) {
            text += "S\t" + id + "\n";
            for (const auto& [name, window] : windows)
                text += name + "\t" + window.identity + "\t" + std::to_string(window.size.width) + "\t" + std::to_string(window.size.height) + "\n";
        }
        require(text.size() <= maxBytes, "Protocol state exceeds size limit");
        const auto temp = ".protocol-" + token();
        int fd = openat(directory, temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        require(fd >= 0, "Cannot create protocol checkpoint");
        try {
            size_t pos = 0;
            while (pos < text.size()) {
                const auto n = write(fd, text.data() + pos, text.size() - pos);
                if (n < 0 && errno == EINTR) continue;
                require(n > 0, "Cannot write protocol checkpoint");
                pos += n;
            }
            require(!fsync(fd), "Cannot sync protocol checkpoint");
            const int result = close(fd); fd = -1;
            require(!result, "Cannot close protocol checkpoint");
            require(!renameat(directory, temp.c_str(), directory, "protocol.tsv"), "Cannot publish protocol checkpoint");
            if (fsync(directory)) {
                healthy = false; // Published, but durability cannot be promised.
                throw std::runtime_error("Cannot sync protocol directory");
            }
        } catch (...) {
            if (fd >= 0) close(fd);
            unlinkat(directory, temp.c_str(), 0);
            throw;
        }
    }
    template<class F> void change(F action) {
        // Bounded copy permits rollback on validation or write failure.
        require(healthy, "Protocol storage is unavailable");
        auto previous = sessions;
        try { action(sessions); save(); }
        catch (...) { if (healthy) sessions = std::move(previous); throw; }
    }
};
}
