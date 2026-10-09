#pragma once
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <thread>
#include <cmath>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}
#include "filesystem.hpp"

namespace SessionIO {
// Only copied plain values cross threads; never a compositor object or Lua reference.
struct Value {
    int type = LUA_TNIL;
    bool boolean = false, integer = false;
    lua_Integer integral = 0;
    lua_Number number = 0;
    std::string text;
    std::vector<std::pair<Value, Value>> fields;
};
struct Budget { size_t nodes = 0, bytes = 0; };
inline Value copy(lua_State* L, int index, Budget& budget, unsigned depth = 0) {
    if (depth > 16 || ++budget.nodes > 65536) throw std::runtime_error("File task exceeds table limit");
    index = lua_absindex(L, index);
    Value value;
    value.type = lua_type(L, index);
    switch (value.type) {
        case LUA_TNIL: break;
        case LUA_TBOOLEAN: value.boolean = lua_toboolean(L, index); break;
        case LUA_TNUMBER:
            value.integer = lua_isinteger(L, index);
            value.integral = value.integer ? lua_tointeger(L, index) : 0;
            value.number = lua_tonumber(L, index);
            if (!std::isfinite(value.number)) throw std::runtime_error("Non-finite file task value");
            break;
        case LUA_TSTRING: {
            size_t size = 0;
            const char* text = lua_tolstring(L, index, &size);
            budget.bytes += size;
            if (budget.bytes > 4 * 1024 * 1024) throw std::runtime_error("File task exceeds byte limit");
            value.text.assign(text, size);
            break;
        }
        case LUA_TTABLE:
            if (lua_getmetatable(L, index)) { lua_pop(L, 1); throw std::runtime_error("File tasks require plain tables"); }
            lua_pushnil(L);
            while (lua_next(L, index)) {
                if (lua_type(L, -2) != LUA_TSTRING && lua_type(L, -2) != LUA_TNUMBER)
                    throw std::runtime_error("Invalid file task key");
                auto key = copy(L, -2, budget, depth + 1);
                auto item = copy(L, -1, budget, depth + 1);
                value.fields.emplace_back(std::move(key), std::move(item));
                lua_pop(L, 1);
            }
            break;
        default: throw std::runtime_error("File tasks cannot contain functions or live objects");
    }
    return value;
}
inline void push(lua_State* L, const Value& value) {
    if (!lua_checkstack(L, 40)) throw std::runtime_error("File task Lua stack exhausted");
    switch (value.type) {
        case LUA_TNIL: lua_pushnil(L); break;
        case LUA_TBOOLEAN: lua_pushboolean(L, value.boolean); break;
        case LUA_TNUMBER:
            if (value.integer) lua_pushinteger(L, value.integral); else lua_pushnumber(L, value.number);
            break;
        case LUA_TSTRING: lua_pushlstring(L, value.text.data(), value.text.size()); break;
        case LUA_TTABLE:
            lua_newtable(L);
            for (const auto& [key, item] : value.fields) { push(L, key); push(L, item); lua_rawset(L, -3); }
            break;
    }
}
struct Job { uint64_t id, epoch; std::string operation; std::vector<Value> arguments; };
struct Result {
    std::vector<Value> values;
    std::string error;
};
class Worker {
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Job> jobs;
    std::map<uint64_t, Result> results;
    uint64_t serial = 0, epoch = 0;
    std::set<uint64_t> pending;
    bool stopping = false;
    std::thread thread;

    void run(lua_CFunction inspect, lua_CFunction validate, const std::string& script) {
        lua_State* L = luaL_newstate();
        std::string initialization;
        if (!L) initialization = "Cannot create file-worker Lua state";
        else {
            luaL_openlibs(L);
            lua_newtable(L); // hl
            lua_newtable(L); // plugin
            lua_newtable(L); // window_session
            lua_pushboolean(L, true); lua_setfield(L, -2, "file_worker");
            const luaL_Reg functions[] = {
                {"desktop_files", SessionFiles::desktop_files}, {"process_command", SessionFiles::process_command},
                {"archive_snapshot", SessionFiles::archive_snapshot},
                {"inspect_state", inspect}, {"validate", validate}, {nullptr, nullptr},
            };
            luaL_setfuncs(L, functions, 0);
            lua_setfield(L, -2, "window_session"); lua_setfield(L, -2, "plugin"); lua_setglobal(L, "hl");
            if (luaL_loadfile(L, script.c_str()) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK)
                initialization = lua_tostring(L, -1) ? lua_tostring(L, -1) : "Cannot load file-worker controller";
        }
        for (;;) {
            Job job;
            {
                std::unique_lock lock(mutex);
                wake.wait(lock, [&] { return stopping || !jobs.empty(); });
                if (jobs.empty()) break;
                job = std::move(jobs.front()); jobs.pop_front();
            }
            Result result;
            try {
                if (!initialization.empty()) throw std::runtime_error(initialization);
                lua_settop(L, 1);
                lua_getfield(L, 1, "file_work");
                lua_pushlstring(L, job.operation.data(), job.operation.size());
                for (const auto& value : job.arguments) push(L, value);
                if (lua_pcall(L, job.arguments.size() + 1, LUA_MULTRET, 0) != LUA_OK)
                    throw std::runtime_error(lua_tostring(L, -1) ? lua_tostring(L, -1) : "File task failed");
                Budget budget;
                for (int i = 2; i <= lua_gettop(L); ++i) result.values.push_back(copy(L, i, budget));
            } catch (const std::exception& error) { result.error = error.what(); }
            {
                std::lock_guard lock(mutex);
                if (job.epoch == epoch) results.emplace(job.id, std::move(result));
            }
        }
        if (L) lua_close(L);
    }
public:
    Worker(lua_CFunction inspect, lua_CFunction validate, const std::string& script)
        : thread([=, this] { run(inspect, validate, script); }) {}
    ~Worker() {
        { std::lock_guard lock(mutex); stopping = true; }
        wake.notify_one();
        thread.join(); // Finish queued checkpoints before unloading their implementation.
    }
    void reset() {
        std::lock_guard lock(mutex);
        ++epoch; pending.clear(); results.clear(); jobs.clear();
    }
    uint64_t submit(std::string operation, std::vector<Value> arguments) {
        std::lock_guard lock(mutex);
        if (stopping || pending.size() >= 16) throw std::runtime_error("File worker is unavailable or full");
        const auto id = ++serial;
        jobs.push_back({id, epoch, std::move(operation), std::move(arguments)});
        pending.insert(id); wake.notify_one(); return id;
    }
    bool take(uint64_t id, Result& result) {
        std::lock_guard lock(mutex);
        if (!pending.contains(id)) throw std::runtime_error("Unknown or expired file task");
        auto it = results.find(id);
        if (it == results.end()) return false;
        result = std::move(it->second); results.erase(it); pending.erase(id); return true;
    }
};
inline std::unique_ptr<Worker> worker;
inline int submit(lua_State* L) {
    const int top = lua_gettop(L);
    try {
        if (!worker || lua_type(L, 1) != LUA_TSTRING) throw std::runtime_error("File worker unavailable");
        size_t size = 0;
        const char* name = lua_tolstring(L, 1, &size);
        if (size > 32) throw std::runtime_error("Invalid file operation");
        std::string operation(name, size);
        Budget budget;
        std::vector<Value> arguments;
        for (int i = 2; i <= top; ++i) arguments.push_back(copy(L, i, budget));
        lua_pushinteger(L, worker->submit(std::move(operation), std::move(arguments))); return 1;
    } catch (const std::exception& error) { lua_settop(L, top); return SessionFiles::failure(L, error); }
}
inline int poll(lua_State* L) {
    try {
        if (!worker || !lua_isinteger(L, 1)) throw std::runtime_error("Invalid file task");
        Result result;
        if (!worker->take(lua_tointeger(L, 1), result)) { lua_pushboolean(L, false); return 1; }
        lua_pushboolean(L, true);
        lua_pushboolean(L, result.error.empty());
        if (!result.error.empty()) { lua_pushlstring(L, result.error.data(), result.error.size()); return 3; }
        for (const auto& value : result.values) push(L, value);
        return 2 + result.values.size();
    } catch (const std::exception& error) { return SessionFiles::failure(L, error); }
}
inline void stop() { worker.reset(); }
}
