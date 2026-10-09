#pragma once
#include <cstring>
#include <memory>
#include <set>
#include <tuple>
#include <hyprland/src/protocols/XDGShell.hpp>
#if __has_include(<hyprland/protocols/xx-session-management-v1.hpp>) || __has_include(<hyprland/protocols/xdg-session-management-v1.hpp>)
#error Review Hyprland native session-management support before advertising another global
#endif
#include "session-store.hpp"
#include "xx-session-management-v1-server.h"

namespace SessionProtocol {
class Protocol final : public IWaylandProtocol {
    struct Client {
        wl_listener destroy{}; // First member, used by the C callback.
        Protocol* owner;
        wl_client* client;
        bool alive = true;
        ~Client() { wl_list_remove(&destroy.link); }
    };
    struct Lease {
        std::shared_ptr<Client> client;
        std::string id;
        wl_resource* resource = nullptr;
        bool active = true;
    };
    struct Destruction {
        wl_listener listener{};
        Protocol* owner = nullptr;
        CXDGToplevelResource* key = nullptr;
        Destruction() { wl_list_init(&listener.link); }
        ~Destruction() { wl_list_remove(&listener.link); }
        void reset() { wl_list_remove(&listener.link); wl_list_init(&listener.link); }
    };
    struct Top {
        WP<CXDGToplevelResource> xdg;
        std::shared_ptr<Lease> lease;
        std::string name, current, restored;
        wl_resource* resource = nullptr;
        wl_resource* xdgResource = nullptr;
        bool attached = false, alive = true, awaiting = false;
        Size initial;
        CHyprSignalListener commit, map;
        Destruction destroy;
    };
    enum Kind { MANAGER, SESSION, TOPLEVEL };
    struct Resource {
        Protocol* owner;
        Kind kind;
        wl_resource* resource;
        std::shared_ptr<Client> client;
        std::shared_ptr<Lease> lease;
        std::shared_ptr<Top> top;
    };
    std::unique_ptr<Store> backing;
    Store& store;
    std::set<std::string> ignored;
    bool stopping = false, dirty = false, closed = false;
    wl_event_source* checkpoint = nullptr;
    std::map<wl_client*, std::shared_ptr<Client>> clients;
    std::map<std::string, std::weak_ptr<Lease>> leases;
    std::map<wl_resource*, std::unique_ptr<Resource>> resources;
    std::map<CXDGToplevelResource*, std::shared_ptr<Top>> tops;

    static bool live(const std::shared_ptr<Lease>& lease) {
        return lease && lease->active && lease->client->alive;
    }
    static Resource& get(wl_resource* resource) {
        return *static_cast<Resource*>(wl_resource_get_user_data(resource));
    }
    template<class F> static void request(wl_resource* resource, F action) noexcept {
        try {
            auto& r = get(resource);
            require(!r.owner->stopping && r.owner->store.healthy, "Session persistence is unavailable");
            action(r);
        }
        catch (const std::bad_alloc&) { wl_resource_post_no_memory(resource); }
        catch (const std::exception& error) {
            wl_client_post_implementation_error(wl_resource_get_client(resource), "%s", error.what());
        }
        catch (...) { wl_client_post_implementation_error(wl_resource_get_client(resource), "Session protocol failure"); }
    }
    static void destroyRequest(wl_client*, wl_resource* resource) { wl_resource_destroy(resource); }
    static void destroyed(wl_resource* resource) {
        auto& r = get(resource);
        auto* owner = r.owner;
        if (r.kind == SESSION) {
            r.lease->active = false;
            r.lease->resource = nullptr;
        } else if (r.kind == TOPLEVEL && r.top && r.top->resource == resource) {
            // Object destruction is NOT removal of the associated window.
            r.top->resource = nullptr;
        }
        owner->resources.erase(resource);
    }
    std::shared_ptr<Client> client(wl_client* handle) {
        if (const auto it = clients.find(handle); it != clients.end()) return it->second;
        uid_t uid = -1;
        wl_client_get_credentials(handle, nullptr, &uid, nullptr);
        require(uid == geteuid() && clients.size() < 128, "Session client is foreign or exceeds limit");
        auto c = std::make_shared<Client>();
        c->owner = this; c->client = handle;
        wl_list_init(&c->destroy.link);
        c->destroy.notify = [](wl_listener* listener, void*) {
            auto* raw = reinterpret_cast<Client*>(listener);
            auto keep = raw->owner->clients.at(raw->client);
            // This precedes resource destruction: disconnect preserves state,
            // whereas an explicit xdg_toplevel.destroy removes its state.
            keep->alive = false;
            wl_list_remove(&keep->destroy.link);
            wl_list_init(&keep->destroy.link);
            keep->owner->clients.erase(keep->client);
        };
        clients.emplace(handle, c);
        wl_client_add_destroy_listener(handle, &c->destroy);
        return c;
    }
    Resource& create(wl_client* handle, uint32_t id, Kind kind, const wl_interface* interface, const void* implementation) {
        require(resources.size() < 1024, "Session resource limit exceeded");
        auto context = client(handle);
        auto r = std::make_unique<Resource>();
        r->owner = this; r->kind = kind; r->client = std::move(context);
        r->resource = wl_resource_create(handle, interface, 1, id);
        if (!r->resource) throw std::bad_alloc();
        const auto resource = r->resource;
        try { resources.emplace(resource, std::move(r)); }
        catch (...) { wl_resource_destroy(resource); throw; }
        auto& result = *resources.at(resource);
        wl_resource_set_implementation(resource, implementation, &result, destroyed);
        return result;
    }
    void getSession(Resource& manager, uint32_t id, uint32_t reason, const char* supplied) {
        require(reason >= 1 && reason <= 3, "Invalid session restoration reason");
        require(!supplied || strnlen(supplied, 513) <= 512, "Session token exceeds limit");
        const bool restore = supplied && store.sessions.contains(supplied);
        auto name = restore ? std::string(supplied) : token();
        auto previous = leases.contains(name) ? leases.at(name).lock() : nullptr;
        if (live(previous) && previous->client == manager.client) {
            wl_resource_post_error(manager.resource, XX_SESSION_MANAGER_V1_ERROR_IN_USE, "Session already in use by this client");
            return;
        }
        if (!restore) store.change([&](auto& data) { require(data.emplace(name, Store::Windows{}).second, "Session token collision"); });
        auto lease = std::make_shared<Lease>();
        lease->id = name; lease->client = manager.client;
        auto& r = create(manager.client->client, id, SESSION, &xx_session_v1_interface, &sessionImpl);
        r.lease = lease; lease->resource = r.resource;
        leases[name] = lease;
        if (live(previous)) {
            xx_session_v1_send_replaced(previous->resource);
            previous->active = false;
        }
        if (restore) xx_session_v1_send_restored(r.resource);
        else xx_session_v1_send_created(r.resource, name.c_str());
    }
    void removeSession(Resource& r) {
        if (live(r.lease)) {
            store.change([&](auto& data) { data.erase(r.lease->id); });
            leases.erase(r.lease->id);
        }
        wl_resource_destroy(r.resource);
    }
    void forget(const std::shared_ptr<Top>& top) {
        if (!top->attached || !live(top->lease)) return;
        store.change([&](auto& data) { data.at(top->lease->id).erase(top->name); });
        top->attached = false;
        top->awaiting = false;
        top->current.clear();
        // Chromium removes the old ID and adds the new ID before mapping.
        // Keep the restore lineage on this physical xdg_toplevel only.
    }
    void commit(const std::shared_ptr<Top>& top) {
        if (stopping || !top->alive || !top->attached || !live(top->lease)) return;
        const auto xdg = top->xdg.lock();
        const auto surface = xdg ? xdg->m_owner.lock() : nullptr;
        if (!surface) return;
        if (ignored.contains(xdg->m_state.appid)) { forget(top); return; }
        if (top->awaiting && surface->m_initialCommit) {
            top->awaiting = false;
            // commit is emitted after applying the initial empty surface state,
            // and configure is scheduled by Hyprland for a later event-loop turn.
            xdg->setSize({top->initial.width, top->initial.height});
            if (top->resource) xx_toplevel_session_v1_send_restored(top->resource, top->xdgResource);
        }
        const auto box = surface->m_current.geometry;
        if (box.w <= 0 || box.h <= 0 || box.w > 1048576 || box.h > 1048576) return;
        const Size size{static_cast<int>(box.w), static_cast<int>(box.h)};
        if (store.sessions.at(top->lease->id).at(top->name).size == size) return;
        if (!dirty) require(!wl_event_source_timer_update(checkpoint, 250), "Cannot schedule protocol checkpoint");
        dirty = true;
        store.sessions.at(top->lease->id).at(top->name).size = size;
    }
    void flush() {
        if (!dirty) return;
        store.save();
        dirty = false;
    }
    void track(Resource& session, uint32_t id, wl_resource* resource, const char* rawName, bool restore) {
        // Inert objects must still consume new_id requests, but have no effect.
        if (!live(session.lease)) {
            create(session.client->client, id, TOPLEVEL, &xx_toplevel_session_v1_interface, &topImpl);
            return;
        }
        require(rawName && strnlen(rawName, 513) <= 512, "Toplevel name exceeds limit");
        require(resource && wl_resource_get_client(resource) == session.client->client, "Foreign toplevel");
        auto xdg = CXDGToplevelResource::fromResource(resource);
        require(xdg && xdg->m_owner, "Toplevel is unavailable");
        if (ignored.contains(xdg->m_state.appid)) {
            store.change([&](auto& data) { data.at(session.lease->id).erase(hex(rawName)); });
            create(session.client->client, id, TOPLEVEL, &xx_toplevel_session_v1_interface, &topImpl);
            return;
        }
        if (restore && !xdg->m_owner->m_initialCommit) {
            wl_resource_post_error(session.resource, XX_SESSION_V1_ERROR_ALREADY_MAPPED, "Restore must precede first surface commit");
            return;
        }
        const auto name = hex(rawName);
        for (const auto& [_, top] : tops) {
            if (!top->attached || !live(top->lease)) continue;
            if (top->xdg.lock() == xdg || (top->lease == session.lease && top->name == name)) {
                wl_resource_post_error(session.resource, XX_SESSION_V1_ERROR_NAME_IN_USE, "Toplevel or name already managed");
                return;
            }
        }
        require(tops.contains(xdg.get()) || tops.size() < Store::maxWindows, "Too many live session toplevels");
        const auto& names = store.sessions.at(session.lease->id);
        const auto found = names.find(name);
        const bool known = restore && found != names.end();
        // Client names may be reused after remove or a fresh add. A compositor
        // generation prevents stale desktop snapshots binding to a new window.
        const Window state = known ? found->second : Window{Size{}, token()};
        const auto initial = state.size;
        store.change([&](auto& data) { data.at(session.lease->id)[name] = state; });
        auto top = tops.contains(xdg.get()) ? tops.at(xdg.get()) : std::make_shared<Top>();
        if (top->lease != session.lease) top->restored.clear();
        top->xdg = xdg; top->xdgResource = resource; top->lease = session.lease;
        top->name = name; top->current = session.lease->id + "/" + state.identity;
        if (restore) top->restored = known ? top->current : std::string{};
        top->attached = true; top->initial = initial;
        top->awaiting = known && initial.width > 0 && initial.height > 0;
        auto& r = create(session.client->client, id, TOPLEVEL, &xx_toplevel_session_v1_interface, &topImpl);
        r.top = top; top->resource = r.resource;
        tops[xdg.get()] = top;
        std::weak_ptr<Top> weak = top;
        auto observe = [this, weak] {
            if (const auto t = weak.lock()) {
                try { commit(t); }
                catch (const std::exception& e) {
                    if (live(t->lease)) wl_client_post_implementation_error(t->lease->client->client, "%s", e.what());
                }
            }
        };
        top->commit = xdg->m_owner->m_events.commit.listen(observe);
        top->map = xdg->m_owner->m_events.map.listen(observe);
        top->destroy.reset();
        top->destroy.owner = this; top->destroy.key = xdg.get();
        top->destroy.listener.notify = [](wl_listener* listener, void*) {
            auto* observer = reinterpret_cast<Destruction*>(listener);
            auto* owner = observer->owner;
            const auto t = owner->tops.at(observer->key);
            try { if (!owner->stopping) owner->forget(t); }
            catch (const std::exception& e) {
                if (live(t->lease)) wl_client_post_implementation_error(t->lease->client->client, "%s", e.what());
            }
            t->alive = false; t->attached = false; t->awaiting = false;
            t->destroy.reset();
            owner->tops.erase(observer->key);
        };
        // Observe the actual wl_resource lifetime, not deferred C++ destruction.
        wl_resource_add_destroy_listener(resource, &top->destroy.listener);
        // add_toplevel is also valid after mapping.
        if (!restore && !xdg->m_owner->m_initialCommit) commit(top);
    }
    inline static const struct xx_session_manager_v1_interface managerImpl = {
        destroyRequest,
        [](wl_client*, wl_resource* r, uint32_t id, uint32_t reason, const char* session) {
            request(r, [&](Resource& value) { value.owner->getSession(value, id, reason, session); });
        },
    };
    inline static const struct xx_session_v1_interface sessionImpl = {
        destroyRequest,
        [](wl_client*, wl_resource* r) { request(r, [](Resource& value) { value.owner->removeSession(value); }); },
        [](wl_client*, wl_resource* r, uint32_t id, wl_resource* top, const char* name) {
            request(r, [&](Resource& value) { value.owner->track(value, id, top, name, false); });
        },
        [](wl_client*, wl_resource* r, uint32_t id, wl_resource* top, const char* name) {
            request(r, [&](Resource& value) { value.owner->track(value, id, top, name, true); });
        },
    };
    inline static const struct xx_toplevel_session_v1_interface topImpl = {
        destroyRequest,
        [](wl_client*, wl_resource* r) {
            request(r, [](Resource& value) {
                if (value.top && value.top->alive && value.top->resource == value.resource) value.owner->forget(value.top);
                wl_resource_destroy(value.resource);
            });
        },
    };
public:
    explicit Protocol(std::unique_ptr<Store> loaded)
        : IWaylandProtocol(&xx_session_manager_v1_interface, 1, "hyprcachy-session-management"), backing(std::move(loaded)), store(*backing) {
        require(getGlobal() != nullptr, "Could not create session-management global");
        // Batch resize commits without a worker or writes on every video frame.
        checkpoint = wl_event_loop_add_timer(wl_display_get_event_loop(wl_global_get_display(getGlobal())), [](void* data) {
            auto* self = static_cast<Protocol*>(data);
            try { self->flush(); }
            catch (...) { self->stopping = true; fputs("window-session: protocol checkpoint failed; persistence stopped\n", stderr); }
            return 0;
        }, this);
        require(checkpoint != nullptr, "Could not create protocol checkpoint timer");
    }
    ~Protocol() override { shutdown(); }
    void onDisplayDestroy() override {
        shutdown(); // The event loop is still alive during this notification.
        IWaylandProtocol::onDisplayDestroy();
    }
    void shutdown() noexcept {
        if (closed) return;
        closed = stopping = true;
        if (checkpoint) { wl_event_source_remove(checkpoint); checkpoint = nullptr; }
        try { flush(); } catch (...) { fputs("window-session: final protocol checkpoint failed\n", stderr); }
        removeGlobal();
        // Disconnect listeners while all plugin code and Hyprland resources are
        // still alive, then destroy every bound object before the DSO unloads.
        for (auto& [_, t] : tops) { t->commit.reset(); t->map.reset(); t->destroy.reset(); }
        while (!resources.empty()) wl_resource_destroy(resources.begin()->first);
        tops.clear(); leases.clear(); clients.clear();
    }
    void bindManager(wl_client* client, void*, uint32_t version, uint32_t id) override {
        try {
            require(version == 1, "Unsupported session protocol version");
            require(!stopping && store.healthy, "Session persistence is unavailable");
            create(client, id, MANAGER, &xx_session_manager_v1_interface, &managerImpl);
        }
        catch (const std::bad_alloc&) { wl_client_post_no_memory(client); }
        catch (const std::exception& e) { wl_client_post_implementation_error(client, "%s", e.what()); }
    }
    void setIgnored(std::set<std::string> classes) {
        ignored = std::move(classes);
        for (const auto& [_, top] : tops)
            if (auto xdg = top->xdg.lock(); xdg && ignored.contains(xdg->m_state.appid)) forget(top);
    }
    // current = future capture identity; restored = original snapshot identity.
    std::tuple<std::string, std::string, bool> identify(CXDGToplevelResource* xdg) const {
        const auto it = tops.find(xdg);
        if (it == tops.end()) return {};
        const auto& top = it->second;
        const bool active = !stopping && top->attached && live(top->lease);
        return {active ? top->current : "", active ? top->restored : "", top->attached};
    }
    int identity(lua_State* L) const {
        const auto window = SessionState::window(L, 1);
        const auto xdg = window->m_xdgSurface ? window->m_xdgSurface->m_toplevel.lock() : nullptr;
        const auto [current, restored, managed] = identify(xdg.get());
        if (!current.empty()) lua_pushlstring(L, current.data(), current.size()); else lua_pushnil(L);
        if (!restored.empty()) lua_pushlstring(L, restored.data(), restored.size()); else lua_pushnil(L);
        lua_pushboolean(L, managed);
        return 3;
    }
};
inline std::unique_ptr<Protocol> protocol;
inline std::string protocolPath, preparedPath;
inline std::unique_ptr<Store> preparedStore;
inline void prepare() {
    // Config-declared PLUGIN_INIT runs before compositor readiness, outside Lua callbacks.
    const auto dir = SessionFiles::state_directory();
    SessionFiles::prepare_directory(dir);
    auto loaded = std::make_unique<Store>(dir.string());
    preparedPath = dir.string();
    preparedStore = std::move(loaded);
}
inline int start(lua_State* L) {
    try {
        const auto path = SessionFiles::path(L).string();
        require(lua_istable(L, 2) && lua_rawlen(L, 2) <= 256, "Expected bounded protocol ignore list");
        std::set<std::string> ignored;
        for (size_t i = 1; i <= lua_rawlen(L, 2); ++i) {
            lua_rawgeti(L, 2, i);
            size_t size = 0;
            const char* value = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &size) : nullptr;
            require(value && size <= 4096 && !memchr(value, 0, size), "Invalid ignored class");
            ignored.emplace(value, size);
            lua_pop(L, 1);
        }
        if (!protocol) {
            require(preparedStore && preparedPath == path, "Restart Hyprland to prepare the protocol state directory");
            auto next = std::make_unique<Protocol>(std::move(preparedStore));
            protocolPath = path;
            protocol = std::move(next);
        }
        preparedStore.reset();
        preparedPath.clear();
        require(protocolPath == path, "Restart Hyprland before changing the protocol state directory");
        protocol->setIgnored(std::move(ignored));
        lua_pushboolean(L, true); return 1;
    } catch (const std::exception& e) { return SessionFiles::failure(L, e); }
}
inline int identity(lua_State* L) {
    try {
        if (protocol) return protocol->identity(L);
        lua_pushnil(L); lua_pushnil(L); lua_pushboolean(L, false); return 3;
    } catch (const std::exception& e) { return SessionState::failure(L, e.what()); }
}
inline void stop() { protocol.reset(); protocolPath.clear(); preparedStore.reset(); preparedPath.clear(); }
}
