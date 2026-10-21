// group_registry.dart — the calculation-group registry (design 06 phase 1b).
//
// Types moved verbatim from edge's lib/compute/groups/group_types.dart (same
// API). Pure Dart, const-constructible. This file is a RED-phase stub:
// [kAnalyticsGroupRegistry] is empty until the green phase declares the real
// groups. test/registry_closure_test.dart pins what it must contain.

/// What a group is. Foundations carry no cost rule; edge transforms are the
/// gating/assembly steps edge runs around analytics results.
enum GroupKind { algorithm, foundation, edgeTransform }

/// How far in time a declared input reaches.
enum InputScope { day, dayAndNext, range, global }

class InputDecl {
  /// An id from edge's input catalogue.
  final String id;
  final InputScope scope;
  const InputDecl(this.id, this.scope);
}

class GroupDecl {
  /// Stable; never reused after a split or merge.
  final String id;
  final GroupKind kind;

  /// Plain integer, bumped when the group's algorithm changes.
  final int counter;

  /// Exported function names, at most 3.
  final List<String> members;

  /// Group ids this group reads, foundations included.
  final List<String> deps;
  final List<InputDecl> inputs;

  /// Repo-relative paths (lib/src/...) this group's output depends on.
  final List<String> files;

  const GroupDecl({
    required this.id,
    required this.kind,
    required this.counter,
    required this.members,
    this.deps = const [],
    this.inputs = const [],
    this.files = const [],
  });
}

class GroupRegistry {
  final int registryVersion;
  final List<GroupDecl> groups;
  const GroupRegistry(this.registryVersion, this.groups);
}

/// The groups analytics declares. STUB: empty until green.
const GroupRegistry kAnalyticsGroupRegistry = GroupRegistry(1, <GroupDecl>[]);
