#include <algorithm>
#include <format>
#include <map>
#include <vector>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.hpp>
#include <hyprland/src/layout/target/Target.hpp>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include "tree.hpp"
#include "filesystem.hpp"
#include "window-state.hpp"

namespace {
using Node = Layout::Tiled::SDwindleNodeData;
using Pointer = SP<Node>;
using Assignment = SessionTree::Assignment<Pointer>;

struct LiveTree {
    PHLWORKSPACE workspace;
    Layout::Tiled::CDwindleAlgorithm* algorithm;
    Pointer root;
    std::map<std::string, Pointer> leaves;
    std::vector<Pointer> branches;
    std::set<Node*> visited;

    void collect(Pointer node, Pointer parent = {}, unsigned depth = 0) {
        SessionTree::require(node && node->valid && depth <= 128 && visited.size() < 511
                                && visited.insert(node.get()).second, "Invalid live dwindle tree");
        SessionTree::require(node->pParent.lock() == parent, "Inconsistent live parent link");
        if (node->isNode) {
            branches.push_back(node);
            collect(node->children[0].lock(), node, depth + 1);
            collect(node->children[1].lock(), node, depth + 1);
        } else {
            const auto target = node->pTarget.lock();
            SessionTree::require(target && target->type() == Layout::TARGET_TYPE_WINDOW && !target->floating()
                                    && target->workspace() == workspace, "Groups/foreign targets are not supported");
            const auto window = target->window();
            SessionTree::require(window && leaves.emplace(std::to_string(window->m_stableID), node).second,
                                "Duplicate or missing live window");
        }
    }

    explicit LiveTree(lua_State* L) {
        SessionTree::require(lua_isinteger(L, 1), "Expected workspace ID");
        workspace = State::workspaceState()->query().id(lua_tointeger(L, 1)).run();
        SessionTree::require(workspace && !workspace->m_isSpecialWorkspace && workspace->m_space,
                            "Workspace is unavailable or special");
        const auto algo = workspace->m_space->algorithm();
        algorithm = algo ? dynamic_cast<Layout::Tiled::CDwindleAlgorithm*>(algo->tiledAlgo().get()) : nullptr;
        SessionTree::require(algorithm != nullptr, "Only dwindle is supported");
        size_t tiled = 0;
        for (const auto& weak : workspace->m_space->targets()) {
            const auto target = weak.lock();
            if (!target || target->floating()) continue;
            SessionTree::require(target->type() == Layout::TARGET_TYPE_WINDOW, "Grouped layouts are not supported");
            ++tiled;
            if (!root) root = algorithm->getNodeFromWindow(target->window());
        }
        SessionTree::require(root != nullptr, "No tiled windows");
        std::set<Node*> parents;
        while (root && root->pParent) {
            SessionTree::require(parents.insert(root.get()).second && parents.size() <= 128, "Cyclic parent links");
            root = root->pParent.lock();
        }
        collect(root);
        SessionTree::require(leaves.size() == tiled && branches.size() + 1 == tiled, "Incomplete live tree");
    }
};

std::string serialize(const Pointer& node) {
    if (!node->isNode) return "L" + std::to_string(node->pTarget->window()->m_stableID);
    return std::format("{}{:.9g} {} {}", node->splitTop ? 'V' : 'H', node->splitRatio,
                       serialize(node->children[0].lock()), serialize(node->children[1].lock()));
}

int failure(lua_State* L, const char* message) {
    // Returning nil,error avoids lua_error's longjmp across C++ destructors.
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

int validate(lua_State* L) {
    try {
        SessionTree::require(lua_type(L, 1) == LUA_TSTRING, "Expected tree string");
        size_t size = 0;
        const char* text = lua_tolstring(L, 1, &size);
        SessionTree::require(size <= 32768, "Tree exceeds size limit");
        SessionTree::parse(std::string(text, size));
        lua_pushboolean(L, true);
        return 1;
    } catch (const std::exception& error) { return failure(L, error.what()); }
}

int capture(lua_State* L) {
    try {
        LiveTree live(L);
        const auto text = serialize(live.root);
        SessionTree::parse(text); // Validate exact ratio/size bounds before exporting.
        lua_pushlstring(L, text.data(), text.size());
        return 1;
    } catch (const std::exception& error) { return failure(L, error.what()); }
}

int restore(lua_State* L) {
    try {
        SessionTree::require(lua_type(L, 2) == LUA_TSTRING && lua_istable(L, 3), "Expected tree string and bindings table");
        size_t length = 0;
        const char* text = lua_tolstring(L, 2, &length);
        SessionTree::require(length <= 32768, "Tree exceeds size limit");
        auto tree = SessionTree::parse(std::string(text, length));
        tree = SessionTree::remap(std::move(tree), [L](const std::string& slot) {
            lua_pushlstring(L, slot.data(), slot.size());
            lua_rawget(L, 3); // Never invoke user metatables from the parser.
            std::string id;
            if (!lua_isnil(L, -1)) {
                if (lua_type(L, -1) != LUA_TSTRING) {
                    lua_pop(L, 1);
                    throw std::runtime_error("Bindings must be strings");
                }
                size_t size = 0;
                const char* value = lua_tolstring(L, -1, &size);
                if (size > 20) { lua_pop(L, 1); throw std::runtime_error("Invalid binding size"); }
                id.assign(value, size);
            }
            lua_pop(L, 1);
            return id;
        });
        SessionTree::require(bool(tree), "No saved windows remain");
        LiveTree live(L);
        const auto requested = SessionTree::leafSet(*tree);
        std::set<std::string> actual;
        for (const auto& [id, _] : live.leaves) actual.insert(id);
        SessionTree::require(requested == actual, "Live tiled windows differ from saved bindings; leaving layout untouched");

        std::vector<Assignment> next, previous;
        size_t index = 0;
        SessionTree::plan(*tree, Pointer{}, live.leaves, live.branches, index, next);
        SessionTree::require(index == live.branches.size(), "Split count mismatch");
        previous.reserve(next.size());
        for (const auto& item : next) {
            const auto& node = item.node;
            previous.push_back({node, node->pParent.lock(), node->children[0].lock(), node->children[1].lock(),
                                node->splitTop, node->splitRatio});
        }
        auto apply = [](const std::vector<Assignment>& plan) {
            for (const auto& item : plan) {
                item.node->pParent = item.parent;
                item.node->children = {item.first, item.second};
                if (item.node->isNode) {
                    item.node->splitTop = item.vertical;
                    item.node->splitRatio = item.ratio;
                }
            }
        };
        // Reuse only Hyprland-owned nodes: no private-vector hacks, node allocation,
        // hooks or replacement tiling algorithm. Every target remains the same.
        apply(next);
        try { live.algorithm->recalculate(); }
        catch (...) { apply(previous); live.algorithm->recalculate(); throw; }
        lua_pushboolean(L, true);
        return 1;
    } catch (const std::exception& error) { return failure(L, error.what()); }
}

// Called through Hyprland's plugin-owned API after the native plugin is loaded.
int configure(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (luaL_loadfile(L, "/usr/share/hyprcachy/window-session/session.lua") != LUA_OK
        || lua_pcall(L, 0, 1, 0) != LUA_OK)
        return lua_error(L);
    lua_getfield(L, -1, "configure");
    lua_pushvalue(L, 1);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        return lua_error(L);
    return 0;
}
}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    if (HyprlandAPI::getHyprlandVersion(handle).hash != GIT_COMMIT_HASH
        || std::string(__hyprland_api_get_hash()) != __hyprland_api_get_client_hash())
        throw std::runtime_error("hyprcachy-window-session: rebuild for this Hyprland/library ABI");
    if (!HyprlandAPI::addLuaFunction(handle, "window_session", "config", configure)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "capture", capture)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "restore", restore)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "validate", validate)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "capture_state", SessionState::capture)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "inspect_state", SessionState::inspect)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "apply_state", SessionState::apply)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "raise_state", SessionState::raise)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "process_command", SessionFiles::process_command)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "prepare_dir", SessionFiles::prepare_dir)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "archive_snapshot", SessionFiles::archive_snapshot)
        || !HyprlandAPI::addLuaFunction(handle, "window_session", "desktop_files", SessionFiles::desktop_files))
        throw std::runtime_error("hyprcachy-window-session: could not register Lua API");
    SessionState::start();
    return {"hyprcachy-window-session", "Save and restore authoritative dwindle split trees", "Hyprcachy", "development"};
}
APICALL EXPORT void PLUGIN_EXIT() { SessionState::stop(); }
