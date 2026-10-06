#pragma once

#include <cmath>
#include <iomanip>
#include <locale>
#include <sstream>
#include "tree.hpp"
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/config/shared/monitor/MonitorRuleManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
extern "C" {
#include <lua.h>
}

namespace SessionState {
using Alpha = Desktop::Types::SAlphaValue;
using Gradient = Config::CGradientValueData;
using Priority = Desktop::Types::eOverridePriority;
constexpr auto manual = Priority::PRIORITY_SET_PROP;

// Only explicit set-prop values are persisted, not evaluated config/window rules.
#define SESSION_PROPS(X) \
    X(Alpha, alpha) X(Alpha, alphaInactive) X(Alpha, alphaFullscreen) \
    X(bool, allowsInput) X(bool, decorate) X(bool, focusOnActivate) \
    X(bool, keepAspectRatio) X(bool, nearestNeighbor) X(bool, noAnim) \
    X(bool, noBlur) X(bool, noDim) X(bool, noFocus) X(bool, noMaxSize) \
    X(bool, noShadow) X(bool, noShortcutsInhibit) X(bool, opaque) X(bool, dimAround) \
    X(bool, RGBX) X(bool, syncFullscreen) X(bool, tearing) X(bool, xray) \
    X(bool, renderUnfocused) X(bool, noFollowMouse) X(bool, noScreenShare) \
    X(bool, noVRR) X(bool, noAutoHDR) X(bool, persistentSize) X(bool, stayFocused) \
    X(bool, confinePointer) X(int, idleInhibitMode) \
    X(Config::INTEGER, borderSize) X(Config::INTEGER, rounding) X(Config::INTEGER, tonemap) \
    X(Config::FLOAT, roundingPower) X(Config::FLOAT, scrollMouse) X(Config::FLOAT, scrollTouchpad) \
    X(std::string, animationStyle) X(Vector2D, maxSize) X(Vector2D, minSize) \
    X(Gradient, activeBorderColor) X(Gradient, inactiveBorderColor)

inline void require(bool ok, const char* message) { SessionTree::require(ok, message); }
inline double number(std::istream& in) {
    double n = 0;
    require(bool(in >> n) && std::isfinite(n) && std::abs(n) <= 1e9, "Invalid state number");
    return n;
}
inline int count(std::istream& in, int maximum) {
    const auto n = number(in);
    require(n >= 0 && n <= maximum && std::floor(n) == n, "Invalid state count");
    return static_cast<int>(n);
}
inline void end(std::istream& in) {
    in >> std::ws;
    require(in.eof(), "Unexpected state data");
}
inline std::string text(std::istream& in, size_t maximum) {
    std::string s;
    require(bool(in >> std::quoted(s)) && s.size() <= maximum && s.find('\0') == std::string::npos, "Invalid state text");
    return s;
}

template<typename T> std::string encodeValue(const T& v) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(17);
    if constexpr (std::is_same_v<T, Vector2D>) out << v.x << ' ' << v.y;
    else if constexpr (std::is_same_v<T, Alpha>) out << v.alpha << ' ' << v.overridden;
    else if constexpr (std::is_same_v<T, Gradient>) {
        out << v.m_angle << ' ' << v.m_colors.size();
        for (const auto& col : v.m_colors) out << ' ' << col.r << ' ' << col.g << ' ' << col.b << ' ' << col.a;
    } else if constexpr (std::is_same_v<T, std::string>) out << std::quoted(v);
    else out << v;
    return out.str();
}
template<typename T> T decodeValue(const std::string& value) {
    std::istringstream in(value);
    in.imbue(std::locale::classic());
    T v{};
    if constexpr (std::is_same_v<T, Vector2D>) {
        v.x = number(in); v.y = number(in);
        require(v.x >= 0 && v.y >= 0, "Negative size override");
    } else if constexpr (std::is_same_v<T, Alpha>) {
        v.alpha = number(in); v.overridden = count(in, 1);
        require(v.alpha >= 0 && v.alpha <= 1, "Invalid opacity override");
    } else if constexpr (std::is_same_v<T, Gradient>) {
        v.m_angle = number(in);
        const int n = count(in, 32);
        for (int i = 0; i < n; ++i) {
            const auto r = number(in), g = number(in), b = number(in), a = number(in);
            require(r >= 0 && r <= 1 && g >= 0 && g <= 1 && b >= 0 && b <= 1 && a >= 0 && a <= 1, "Invalid border color");
            v.m_colors.emplace_back(r, g, b, a);
            // The constructor takes floats; retain the original public double channels.
            auto& color = v.m_colors.back();
            color.r = r; color.g = g; color.b = b; color.a = a;
        }
        v.updateColorsOk();
    } else if constexpr (std::is_same_v<T, std::string>) v = text(in, 4096);
    else if constexpr (std::is_same_v<T, bool>) v = count(in, 1);
    else {
        const double n = number(in);
        if constexpr (std::is_integral_v<T>) require(std::floor(n) == n, "Non-integer override");
        v = static_cast<T>(n);
    }
    end(in);
    return v;
}
inline void validateProp(const std::string& name, const std::string& value) {
#define CHECK(type, field) if (name == #field) { (void)decodeValue<type>(value); return; }
    SESSION_PROPS(CHECK)
#undef CHECK
    throw std::runtime_error("Unsupported saved override: " + name);
}

struct State {
    bool pseudo = false, above = false;
    Vector2D pseudoSize, floatingSize;
    int z = 0;
    std::optional<CBox> normal; // normalized within the saved floating work area
    std::vector<std::string> tags;
    std::map<std::string, std::string> props;
};
inline State decode(const std::string& data) {
    require(data.size() <= 65536, "Window state exceeds 64 KiB");
    std::istringstream in(data);
    in.imbue(std::locale::classic());
    State s;
    s.pseudo = count(in, 1);
    s.pseudoSize.x = number(in); s.pseudoSize.y = number(in);
    s.floatingSize.x = number(in); s.floatingSize.y = number(in);
    require(s.pseudoSize.x >= 0 && s.pseudoSize.y >= 0 && s.floatingSize.x >= 0 && s.floatingSize.y >= 0, "Invalid remembered size");
    s.z = count(in, 1000000); s.above = count(in, 1);
    if (count(in, 1)) {
        CBox box;
        box.x = number(in); box.y = number(in); box.w = number(in); box.h = number(in);
        require(box.w > 0 && box.h > 0, "Invalid windowed geometry");
        s.normal = box;
    }
    const int tags = count(in, 128);
    std::set<std::string> unique;
    for (int i = 0; i < tags; ++i) {
        auto tag = text(in, 256);
        require(!tag.empty() && !tag.ends_with('*') && unique.insert(tag).second, "Invalid manual tag");
        s.tags.push_back(std::move(tag));
    }
    const int props = count(in, 64);
    for (int i = 0; i < props; ++i) {
        auto key = text(in, 64), value = text(in, 8192);
        validateProp(key, value);
        require(s.props.emplace(key, value).second, "Duplicate saved override");
    }
    end(in);
    return s;
}
inline std::string encode(const State& s) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(17) << s.pseudo << ' ' << encodeValue(s.pseudoSize) << ' '
        << encodeValue(s.floatingSize) << ' ' << s.z << ' ' << s.above << ' ' << s.normal.has_value();
    if (s.normal) out << ' ' << s.normal->x << ' ' << s.normal->y << ' ' << s.normal->w << ' ' << s.normal->h;
    out << ' ' << s.tags.size();
    for (const auto& tag : s.tags) out << ' ' << std::quoted(tag);
    out << ' ' << s.props.size();
    for (const auto& [key, value] : s.props) out << ' ' << std::quoted(key) << ' ' << std::quoted(value);
    auto data = out.str();
    (void)decode(data); // Apply identical bounds to captured and imported data.
    return data;
}

inline std::map<uint64_t, CBox> normalGeometry;
inline CHyprSignalListener frameListener, closeListener;
inline void observe() {
    // ponytail: last-observed geometry; use a public fullscreen-cache getter if Hyprland adds one.
    for (const auto& w : Desktop::windowState()->windows()) {
        if (!w->m_isMapped || w->isHidden() || !w->m_isFloating || w->m_group || !w->m_workspace || !w->m_workspace->m_space
            || !w->m_monitor || Fullscreen::controller()->isFullscreen(w)) continue;
        const auto box = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        const auto area = w->m_monitor->m_reservedArea.apply(w->m_monitor->logicalBox());
        if (box.w > 0 && box.h > 0 && area.w > 0 && area.h > 0)
            normalGeometry[w->m_stableID] = CBox{(box.x - area.x) / area.w, (box.y - area.y) / area.h, box.w / area.w, box.h / area.h};
    }
}
inline void start() {
    frameListener = Event::bus()->m_events.render.pre.listen([](PHLMONITOR) { observe(); });
    closeListener = Event::bus()->m_events.window.close.listen([](PHLWINDOW w) { normalGeometry.erase(w->m_stableID); });
    observe();
}
inline void stop() { frameListener.reset(); closeListener.reset(); normalGeometry.clear(); }
inline PHLWINDOW window(lua_State* L, int index) {
    require(lua_type(L, index) == LUA_TSTRING, "Expected stable window ID");
    size_t n = 0;
    const char* id = lua_tolstring(L, index, &n);
    require(n > 0 && n <= 20, "Invalid window ID");
    for (const auto& w : Desktop::windowState()->windows())
        if (w->m_isMapped && !w->m_group && std::to_string(w->m_stableID) == std::string(id, n)) return w;
    throw std::runtime_error("Window is unavailable or grouped");
}
inline std::string data(lua_State* L, int index) {
    require(lua_type(L, index) == LUA_TSTRING, "Expected window state string");
    size_t n = 0;
    const char* value = lua_tolstring(L, index, &n);
    require(n <= 65536, "Window state exceeds 64 KiB");
    return {value, n};
}
inline int failure(lua_State* L, const char* error) { lua_pushnil(L); lua_pushstring(L, error); return 2; }
inline void info(lua_State* L, const State& s) {
    lua_newtable(L);
    lua_pushinteger(L, s.z); lua_setfield(L, -2, "z");
    lua_newtable(L);
    for (size_t i = 0; i < s.tags.size(); ++i) {
        lua_pushlstring(L, s.tags[i].data(), s.tags[i].size()); lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "tags");
    if (s.normal) {
        lua_newtable(L);
        const double values[] = {s.normal->x, s.normal->y, s.normal->w, s.normal->h};
        for (int i = 0; i < 4; ++i) { lua_pushnumber(L, values[i]); lua_rawseti(L, -2, i + 1); }
        lua_setfield(L, -2, "normal");
    }
}
inline int inspect(lua_State* L) {
    try { info(L, decode(data(L, 1))); return 1; }
    catch (const std::exception& e) { return failure(L, e.what()); }
}
inline int capture(lua_State* L) {
    try {
        const auto w = window(L, 1);
        const auto target = w->layoutTarget();
        require(bool(target), "No layout target");
        observe();
        State s;
        s.pseudo = target->isPseudo(); s.pseudoSize = target->pseudoSize(); s.floatingSize = target->lastFloatingSize();
        s.above = w->m_allowedOverFullscreen;
        const auto& windows = Desktop::windowState()->windows();
        s.z = std::ranges::find(windows, w) - windows.begin();
        if (normalGeometry.contains(w->m_stableID)) s.normal = normalGeometry.at(w->m_stableID);
        const auto& rules = w->m_ruleApplicator;
        for (const auto& tag : rules->m_tagKeeper.getTags()) if (!tag.ends_with('*')) s.tags.push_back(tag);
#define CAPTURE(type, field) if (rules->field().hasValue() && rules->field().getPriority() == manual) s.props[#field] = encodeValue(rules->field().value());
        SESSION_PROPS(CAPTURE)
#undef CAPTURE
        const auto value = encode(s);
        info(L, s);
        lua_pushlstring(L, value.data(), value.size()); lua_setfield(L, -2, "data");
        return 1;
    } catch (const std::exception& e) { return failure(L, e.what()); }
}
inline int apply(lua_State* L) {
    try {
        const auto w = window(L, 1);
        const auto s = decode(data(L, 2)); // Validate the entire record before any mutation.
        require(lua_isboolean(L, 3), "Expected style/layout phase");
        const auto target = w->layoutTarget();
        require(bool(target), "No layout target");
        if (lua_toboolean(L, 3)) {
            auto& rules = w->m_ruleApplicator;
            const auto current = rules->m_tagKeeper.getTags();
            for (const auto& tag : current) if (!tag.ends_with('*')) rules->m_tagKeeper.applyTag("-" + tag);
            for (const auto& tag : s.tags) rules->m_tagKeeper.applyTag("+" + tag);
            rules->propertiesChanged(Desktop::Rule::RULE_PROP_TAG);
#define APPLY(type, field) if (s.props.contains(#field)) rules->field().set(decodeValue<type>(s.props.at(#field)), manual); else rules->field().unset(manual);
            SESSION_PROPS(APPLY)
#undef APPLY
            Desktop::globalWindowController()->updateAllWindowsDecorations();
            if (s.props.contains("minSize") || s.props.contains("maxSize"))
                w->clampWindowSize(s.props.contains("minSize") ? std::optional{rules->minSize().value()} : std::nullopt,
                                   s.props.contains("maxSize") ? std::optional{rules->maxSize().value()} : std::nullopt);
            Config::monitorRuleMgr()->ensureVRR();
        } else {
            target->setPseudoSize(s.pseudoSize); target->setPseudo(s.pseudo);
            target->rememberFloatingSize(s.floatingSize);
            if (s.normal) normalGeometry[w->m_stableID] = *s.normal;
            target->recalc();
        }
        lua_pushboolean(L, true); return 1;
    } catch (const std::exception& e) { return failure(L, e.what()); }
}
inline int raise(lua_State* L) {
    try {
        const auto w = window(L, 1);
        const auto s = decode(data(L, 2));
        require(w->m_isFloating, "Stack restoration requires a floating window");
        Desktop::windowState()->raise(w);
        w->m_allowedOverFullscreen = s.above;
        w->updateFullscreenInputState();
        *w->alpha(Desktop::View::WINDOW_ALPHA_FULLSCREEN) = w->isBlockedByFullscreen() ? 0.F : 1.F;
        lua_pushboolean(L, true); return 1;
    } catch (const std::exception& e) { return failure(L, e.what()); }
}
#undef SESSION_PROPS
}
