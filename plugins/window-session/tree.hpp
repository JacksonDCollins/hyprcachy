#pragma once
#include <charconv>
#include <cmath>
#include <functional>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace SessionTree {
struct Node {
    std::string leaf;
    bool vertical = false;
    float ratio = 1;
    std::unique_ptr<Node> first, second;
};
inline void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
inline bool identifier(const std::string& id) {
    return !id.empty() && id.size() <= 20 && id.find_first_not_of("0123456789") == std::string::npos;
}
inline std::unique_ptr<Node> parseNode(std::istringstream& input, std::set<std::string>& leaves, unsigned depth, unsigned& count) {
    require(depth <= 128 && ++count <= 511, "Tree exceeds safety limits (256 leaves / depth 128)");
    std::string token;
    require(bool(input >> token) && token.size() > 1, "Truncated tree");
    auto node = std::make_unique<Node>();
    const std::string value = token.substr(1);
    if (token[0] == 'L') {
        require(identifier(value) && leaves.insert(value).second, "Invalid or duplicate leaf");
        node->leaf = value;
    } else {
        require(token[0] == 'H' || token[0] == 'V', "Invalid split axis");
        auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), node->ratio);
        require(error == std::errc{} && end == value.data() + value.size() && std::isfinite(node->ratio)
                    && node->ratio >= 0.1F && node->ratio <= 1.9F, "Invalid split ratio");
        node->vertical = token[0] == 'V';
        node->first = parseNode(input, leaves, depth + 1, count);
        node->second = parseNode(input, leaves, depth + 1, count);
    }
    return node;
}
inline std::unique_ptr<Node> parse(const std::string& text) {
    require(text.size() <= 32768, "Tree exceeds size limit");
    std::istringstream input(text);
    std::set<std::string> leaves;
    unsigned count = 0;
    auto root = parseNode(input, leaves, 0, count);
    std::string extra;
    require(!(input >> extra), "Trailing tree data");
    return root;
}
// Missing applications collapse their branch; surviving siblings keep their own
// subtree. Extra live windows are checked separately before any compositor write.
inline std::unique_ptr<Node> remap(std::unique_ptr<Node> node, const std::function<std::string(const std::string&)>& resolve) {
    if (!node->leaf.empty()) {
        node->leaf = resolve(node->leaf);
        require(node->leaf.empty() || identifier(node->leaf), "Invalid mapped window ID");
        return node->leaf.empty() ? nullptr : std::move(node);
    }
    node->first = remap(std::move(node->first), resolve);
    node->second = remap(std::move(node->second), resolve);
    if (!node->first) return std::move(node->second);
    if (!node->second) return std::move(node->first);
    return node;
}
inline std::set<std::string> leafSet(const Node& node) {
    if (!node.leaf.empty()) return {node.leaf};
    auto first = leafSet(*node.first), second = leafSet(*node.second);
    for (const auto& id : second) require(first.insert(id).second, "Bindings map two leaves to one window");
    return first;
}
// Build the entire assignment plan before mutating any node. Node pointers can be
// real Hyprland nodes or fake nodes in the standalone regression check.
template<class Pointer> struct Assignment {
    Pointer node, parent, first, second;
    bool vertical;
    float ratio;
};
template<class Pointer, class Leaves>
Pointer plan(const Node& tree, Pointer parent, const Leaves& leaves, const std::vector<Pointer>& branches,
             size_t& next, std::vector<Assignment<Pointer>>& assignments) {
    if (!tree.leaf.empty()) {
        Pointer node = leaves.at(tree.leaf);
        assignments.push_back({node, parent, {}, {}, false, 1});
        return node;
    }
    require(next < branches.size(), "Insufficient live split nodes");
    Pointer node = branches[next++];
    Pointer first = plan(*tree.first, node, leaves, branches, next, assignments);
    Pointer second = plan(*tree.second, node, leaves, branches, next, assignments);
    assignments.push_back({node, parent, first, second, tree.vertical, tree.ratio});
    return node;
}
}
