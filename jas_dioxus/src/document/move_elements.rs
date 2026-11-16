//! `move_elements(paths, target_parent, index)` — the Layers panel's drop
//! (LAYERS-S2 interaction spec §3, `workspace/actions.yaml` §move_elements).
//!
//! The dragged set is first REDUCED TO ITS ROOTS (ERRATUM 3, DECISION S2-15):
//! a path whose proper ancestor is also dragged travels inside that ancestor,
//! its path within it unchanged, and is never checked or placed on its own.
//! The roots leave their places and are inserted, in their original
//! DOCUMENT order, at `index` under `target_parent`. `index` counts the
//! parent's children in document (z) order, 0 = the bottom child, and is read
//! AFTER the dragged elements are removed (DECISION S2-14). `[]` as the target
//! parent is the document root (the top-level `layers` array).
//!
//! ONE AUTHORITY FOR VALIDITY. [`plan_move`] is the only place the five rules
//! live; the op arm in `op_apply` applies what it plans, and a shell's
//! `drop_valid` must be [`drop_valid`] (which calls it), never a second copy.
//!
//! A path names a POSITION, so a move re-points every stored path: the plan's
//! [`MovePlan::remap`] maps any pre-move path to the post-move path of the same
//! element. The op uses it for the document selection and the model's
//! isolation stack; the `doc.op` effect uses it for every path in the Layers
//! panel's state ([`PANEL_PATH_KEYS`], [`MovePlan::remap_panel_value`]).
//!
//! The op takes NO undo snapshot of its own: the `move_elements` action opens
//! the one undo step with its own `snapshot` effect, and the write here joins
//! it (`Model::edit_document` self-brackets only when nothing is open).

use std::rc::Rc;

use crate::document::document::{Document, ElementPath, ElementSelection};
use crate::geometry::element::Element;

/// Why a drop is refused: the five validity rules, by name (spec §3, ERRATUM 1).
/// The check returns the FIRST failure: the dragged set's ROOTS (ERRATUM 3)
/// are taken in document order and, for each, rules 1–5 in the order listed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveRefusal {
    /// Rule 1: the target parent is a dragged element or inside one.
    IntoItselfOrDescendant,
    /// Rule 2: the target parent is locked, by its own flag or an ancestor's.
    LockedParent,
    /// Rule 3: a layer goes only to the root or a layer; anything else only to
    /// a layer or a group (never the root).
    WrongParentKind,
    /// Rule 4: a search query or a type filter is active.
    FilterActive,
    /// Rule 5: in isolation, the target parent is not the isolated container
    /// or inside it.
    OutsideIsolation,
}

impl MoveRefusal {
    /// The refusal's name, exactly as spec §3 (ERRATUM 1) spells it.
    pub fn name(&self) -> &'static str {
        match self {
            MoveRefusal::IntoItselfOrDescendant => "into_itself_or_descendant",
            MoveRefusal::LockedParent => "locked_parent",
            MoveRefusal::WrongParentKind => "wrong_parent_kind",
            MoveRefusal::FilterActive => "filter_active",
            MoveRefusal::OutsideIsolation => "outside_isolation",
        }
    }
}

/// Everything that stops a move. [`MoveError::Refused`] (a rule) and
/// [`MoveError::NothingToMove`] (empty `paths`) are NOT errors at the op
/// layer: the op succeeds with nothing changed. The others are malformed or
/// absent operands and stay errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MoveError {
    /// One of the five validity rules failed. The op succeeds, unchanged.
    Refused(MoveRefusal),
    /// The paths list is empty: a no-op, not a refusal.
    NothingToMove,
    /// A dragged path or the target parent names no element.
    MissingTarget(ElementPath),
    /// A dragged path is not a Layers-tree row (a Transformed wrapper's child,
    /// which the tree draws as part of its wrapper).
    NotATreeRow(ElementPath),
    /// `index` is past the end of the parent's children after removal.
    IndexOutOfRange,
}

/// The panel state the rules read beyond the document: whether a search or
/// type filter is active (rule 4) and the isolation stack (rule 5).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MoveContext {
    pub filtering: bool,
    /// The isolated containers' paths, in any order. Each level of a nested
    /// isolation lies inside the one before it, so "inside the innermost" is
    /// the same as "inside every entry", which is what rule 5 checks.
    pub isolation_stack: Vec<ElementPath>,
}

/// A validated move, computed against the PRE-move document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MovePlan {
    /// The dragged set's ROOTS (ERRATUM 3): pre-move paths in document order,
    /// with any path inside another dragged path dropped (it travels inside
    /// its root, and [`MovePlan::remap`] still follows it).
    pub moved: Vec<ElementPath>,
    /// The target parent's pre-move path (`[]` = root).
    pub parent: ElementPath,
    /// The target parent's path once the moved elements are removed.
    pub parent_after_removal: ElementPath,
    /// The insertion index under the parent, after removal.
    pub index: usize,
}

/// Validate and plan a move. The one authority for the five rules.
///
/// Checks, in order: an empty `paths` ⇒ [`MoveError::NothingToMove`] (a
/// no-op); every given path (root or not) and the parent resolve ⇒ else
/// [`MoveError::MissingTarget`]; every given path is a tree row; the paths
/// are REDUCED TO THEIR ROOTS (ERRATUM 3, [`roots_in_document_order`]); then,
/// for every ROOT in document order, rules 1–5 in the order listed, returning
/// the FIRST failure ([`MoveError::Refused`], whose [`MoveRefusal::name`] is
/// the spec's name) — a non-root is never checked; finally `index` is within
/// the parent's NON-moved children (after removal).
pub fn plan_move(
    doc: &Document,
    paths: &[ElementPath],
    target_parent: &ElementPath,
    index: usize,
    ctx: &MoveContext,
) -> Result<MovePlan, MoveError> {
    if paths.is_empty() {
        return Err(MoveError::NothingToMove);
    }
    // Every GIVEN path must name a Layers-tree row, a non-root as much as a
    // root: a missing element stays an error (spec §3). Only the five rules
    // are confined to the roots (ERRATUM 3).
    for p in paths.iter().filter(|p| !p.is_empty()) {
        if doc.get_element(p).is_none() {
            return Err(MoveError::MissingTarget(p.clone()));
        }
        let parent = &p[..p.len() - 1];
        if !parent.is_empty() {
            match doc.get_element(&parent.to_vec()) {
                Some(e) if e.children().is_some() => {}
                _ => return Err(MoveError::NotATreeRow(p.clone())),
            }
        }
    }
    // ERRATUM 3: reduce the dragged set to its ROOTS, in document order. A
    // path whose proper ancestor is also dragged is dropped here: it is never
    // checked against the rules and never placed under the target on its
    // own; it travels inside its root, its path within the root unchanged.
    let moved = roots_in_document_order(paths);
    let parent_elem = if target_parent.is_empty() {
        None
    } else {
        match doc.get_element(target_parent) {
            Some(e) => Some(e),
            None => return Err(MoveError::MissingTarget(target_parent.clone())),
        }
    };
    let parent_is_layer = matches!(parent_elem, Some(Element::Layer(_)));
    let parent_is_group = matches!(parent_elem, Some(Element::Group(_)));
    let parent_is_root = target_parent.is_empty();
    for p in &moved {
        // Rule 1: not the element itself, nor inside it.
        if target_parent.starts_with(p) {
            return Err(MoveError::Refused(MoveRefusal::IntoItselfOrDescendant));
        }
        // Rule 2: the parent is not locked (inherited). The root is never locked.
        if doc.effective_locked(target_parent) {
            return Err(MoveError::Refused(MoveRefusal::LockedParent));
        }
        // Rule 3: layers to root or a layer; anything else to a layer or group.
        let kind_ok = match doc.get_element(p) {
            Some(Element::Layer(_)) => parent_is_root || parent_is_layer,
            _ => parent_is_layer || parent_is_group,
        };
        if !kind_ok {
            return Err(MoveError::Refused(MoveRefusal::WrongParentKind));
        }
        // Rule 4: no search query or type filter active.
        if ctx.filtering {
            return Err(MoveError::Refused(MoveRefusal::FilterActive));
        }
        // Rule 5: in isolation, the parent is the isolated container or inside it.
        if !ctx.isolation_stack.iter().all(|iso| target_parent.starts_with(iso)) {
            return Err(MoveError::Refused(MoveRefusal::OutsideIsolation));
        }
    }
    let mut plan = MovePlan {
        moved,
        parent: target_parent.clone(),
        parent_after_removal: Vec::new(),
        index,
    };
    plan.parent_after_removal = plan.removal_shift(target_parent);
    let child_count = match parent_elem {
        None => doc.layers.len(),
        Some(e) => e.children().map(|c| c.len()).unwrap_or(0),
    };
    let removed_here = plan
        .moved
        .iter()
        .filter(|m| m[..m.len() - 1] == target_parent[..])
        .count();
    if index > child_count - removed_here {
        return Err(MoveError::IndexOutOfRange);
    }
    Ok(plan)
}

/// The shell's drop indicator / "not allowed" pointer: exactly whether
/// [`plan_move`] accepts the drop.
pub fn drop_valid(
    doc: &Document,
    paths: &[ElementPath],
    target_parent: &ElementPath,
    index: usize,
    ctx: &MoveContext,
) -> bool {
    plan_move(doc, paths, target_parent, index, ctx).is_ok()
}

/// ERRATUM 3: the dragged set REDUCED TO ITS ROOTS, in document order. Sort
/// into document order (lexicographic on index paths = pre-order, so an
/// ancestor precedes its descendants), dedupe, and drop any path whose proper
/// ancestor is also dragged (it travels inside that ancestor). Empty paths
/// are dropped: the root is not an element.
pub fn roots_in_document_order(paths: &[ElementPath]) -> Vec<ElementPath> {
    let mut sorted: Vec<ElementPath> = paths.iter().filter(|p| !p.is_empty()).cloned().collect();
    sorted.sort();
    sorted.dedup();
    let mut out: Vec<ElementPath> = Vec::with_capacity(sorted.len());
    for p in sorted {
        if !out.iter().any(|a| p.starts_with(a)) {
            out.push(p);
        }
    }
    out
}

impl MovePlan {
    /// The post-removal path of an element that is NOT moved: at every level,
    /// the index drops by the moved siblings that preceded it there.
    fn removal_shift(&self, q: &[usize]) -> ElementPath {
        let mut out = Vec::with_capacity(q.len());
        for k in 0..q.len() {
            let before = self
                .moved
                .iter()
                .filter(|m| m.len() == k + 1 && m[..k] == q[..k] && m[k] < q[k])
                .count();
            out.push(q[k] - before);
        }
        out
    }

    /// Map a PRE-move path to the POST-move path of the same element. The
    /// root (`[]`) maps to itself. A moved element (or anything inside one)
    /// lands under the parent at `index + its rank`; every other element
    /// shifts for the removals before it and the insertion before it.
    pub fn remap(&self, q: &[usize]) -> ElementPath {
        if let Some((rank, m)) = self.moved.iter().enumerate().find(|(_, m)| q.starts_with(m)) {
            let mut out = self.parent_after_removal.clone();
            out.push(self.index + rank);
            out.extend_from_slice(&q[m.len()..]);
            return out;
        }
        let mut r = self.removal_shift(q);
        let d = self.parent_after_removal.len();
        if r.len() > d && r[..d] == self.parent_after_removal[..] && r[d] >= self.index {
            r[d] += self.moved.len();
        }
        r
    }

    /// Apply the move to `doc` (pure). The document selection and the target
    /// layer are carried through [`Self::remap`], so they keep naming the
    /// same elements.
    pub fn apply(&self, doc: &Document) -> Document {
        let mut new_doc = doc.clone();
        let elems: Vec<Rc<Element>> = self
            .moved
            .iter()
            .filter_map(|p| doc.get_element(p).map(|e| Rc::new(e.clone())))
            .collect();
        // Remove in reverse document order, so earlier paths stay valid.
        for p in self.moved.iter().rev() {
            remove_at(&mut new_doc, p);
        }
        let at = self.parent_after_removal.clone();
        for (k, e) in elems.into_iter().enumerate() {
            let i = self.index + k;
            if at.is_empty() {
                new_doc.layers.insert(i, (*e).clone());
            } else if let Some(kids) = new_doc.get_element_mut(&at).and_then(|p| p.children_mut()) {
                kids.insert(i, e);
            }
        }
        new_doc.selection = doc
            .selection
            .iter()
            .map(|es| ElementSelection { path: self.remap(&es.path), kind: es.kind.clone() })
            .collect();
        if let Some(&layer) = self.remap(&[doc.selected_layer]).first() {
            new_doc.selected_layer = layer;
        }
        new_doc
    }

    /// Remap one stored panel-state value under `key` (one of
    /// [`PANEL_PATH_KEYS`]). A path is either the store's `{"__path__": [..]}`
    /// marker or a plain index array, and keeps its form. Anything that is not
    /// a path (null, an isolation entry carrying only an id) is unchanged.
    pub fn remap_panel_value(&self, key: &str, v: &serde_json::Value) -> serde_json::Value {
        match key {
            // A single path, or null.
            "solo_path" | "renaming_element" => self.remap_path_value(v),
            // A list of [path, visibility] pairs.
            "solo_saved" => match v.as_array() {
                Some(items) => serde_json::Value::Array(
                    items
                        .iter()
                        .map(|pair| match pair.as_array() {
                            Some(parts) if !parts.is_empty() => {
                                let mut parts = parts.clone();
                                parts[0] = self.remap_path_value(&parts[0]);
                                serde_json::Value::Array(parts)
                            }
                            _ => pair.clone(),
                        })
                        .collect(),
                ),
                None => v.clone(),
            },
            // A list of paths.
            _ => match v.as_array() {
                Some(items) => serde_json::Value::Array(items.iter().map(|i| self.remap_path_value(i)).collect()),
                None => v.clone(),
            },
        }
    }

    /// Remap one path value, keeping its form (marker or plain array).
    fn remap_path_value(&self, v: &serde_json::Value) -> serde_json::Value {
        if let Some(inner) = v.as_object().and_then(|o| o.get("__path__")) {
            return match path_of(inner) {
                Some(p) => {
                    let mut o = v.as_object().cloned().unwrap_or_default();
                    o.insert("__path__".into(), serde_json::json!(self.remap(&p)));
                    serde_json::Value::Object(o)
                }
                None => v.clone(),
            };
        }
        match path_of(v) {
            Some(p) if !p.is_empty() => serde_json::json!(self.remap(&p)),
            _ => v.clone(),
        }
    }
}

/// The Layers panel's state keys that hold element paths, every one of which
/// a move remaps (spec §3, DECISION S2-10 widened by G17).
pub const PANEL_PATH_KEYS: &[&str] = &[
    "layers_panel_selection",
    "collapsed_paths",
    "isolation_stack",
    "solo_path",
    "renaming_element",
    "solo_saved",
];

/// Remove the element at `p` (a Layers-tree row: its parent is the root, a
/// layer or a group).
fn remove_at(doc: &mut Document, p: &[usize]) {
    let Some((&last, parent)) = p.split_last() else { return };
    if parent.is_empty() {
        if last < doc.layers.len() {
            doc.layers.remove(last);
        }
    } else if let Some(kids) = doc.get_element_mut(&parent.to_vec()).and_then(|e| e.children_mut()) {
        if last < kids.len() {
            kids.remove(last);
        }
    }
}

// ── Reading the op's params ─────────────────────────────────────────────────

/// A plain index array as a path: every entry a non-negative integer (an
/// integral float counts, because the expression layer's numbers are floats).
fn path_of(v: &serde_json::Value) -> Option<ElementPath> {
    let arr = v.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for n in arr {
        let f = n.as_f64()?;
        if f < 0.0 || f.fract() != 0.0 {
            return None;
        }
        out.push(f as usize);
    }
    Some(out)
}

/// A path value: a plain index array or the store's `{"__path__": [..]}`
/// marker.
pub fn parse_path_value(v: Option<&serde_json::Value>) -> Option<ElementPath> {
    let v = v?;
    match v.as_object() {
        Some(o) => path_of(o.get("__path__")?),
        None => path_of(v),
    }
}

/// A list of path values (plain arrays or markers). `None` if the value is not
/// a list or any entry is not a path.
pub fn parse_path_list(v: Option<&serde_json::Value>) -> Option<Vec<ElementPath>> {
    v?.as_array()?.iter().map(|item| parse_path_value(Some(item))).collect()
}

/// The non-negative integral `index` param.
pub fn parse_index(v: Option<&serde_json::Value>) -> Option<usize> {
    let f = v?.as_f64()?;
    (f >= 0.0 && f.fract() == 0.0).then_some(f as usize)
}

/// The rules' context from the op: `search_query` (a non-empty string is a
/// search) and `type_filter` (a non-empty list is a filter) for rule 4;
/// `isolation_stack` (path values; entries that are not paths are skipped)
/// for rule 5, falling back to `model_isolation` when the op does not carry
/// the key.
pub fn context_from_op(op: &serde_json::Value, model_isolation: &[ElementPath]) -> MoveContext {
    let searching = op.get("search_query").and_then(|v| v.as_str()).map_or(false, |s| !s.is_empty());
    let type_filtering = op.get("type_filter").and_then(|v| v.as_array()).map_or(false, |a| !a.is_empty());
    let isolation_stack = match op.get("isolation_stack") {
        Some(v) => v
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|i| {
                        parse_path_value(Some(i)).or_else(|| parse_path_value(i.get("path")))
                    })
                    .collect()
            })
            .unwrap_or_default(),
        None => model_isolation.to_vec(),
    };
    MoveContext { filtering: searching || type_filtering, isolation_stack }
}

/// A parameter fault in a `move_elements` op (before any rule is checked).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamFault {
    Missing(&'static str),
    BadType(&'static str),
}

/// Read and plan a `move_elements` op: the params, then [`plan_move`]. Shared
/// by `op_apply` and the `doc.op` effect so both see the same plan.
pub fn plan_from_op(
    doc: &Document,
    model_isolation: &[ElementPath],
    op: &serde_json::Value,
) -> Result<Result<MovePlan, MoveError>, ParamFault> {
    let fault = |name: &'static str| {
        if op.get(name).is_none() { ParamFault::Missing(name) } else { ParamFault::BadType(name) }
    };
    let paths = parse_path_list(op.get("paths")).ok_or_else(|| fault("paths"))?;
    let parent = parse_path_value(op.get("target_parent")).ok_or_else(|| fault("target_parent"))?;
    let index = parse_index(op.get("index")).ok_or_else(|| fault("index"))?;
    let ctx = context_from_op(op, model_isolation);
    Ok(plan_move(doc, &paths, &parent, index, &ctx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;
    use crate::document::op_apply::{op_apply, OpError};
    use crate::document::test_fixture::{group, rect};
    use crate::geometry::element::{CommonProps, LayerElem};
    use serde_json::json;

    fn named(mut e: Element, name: &str) -> Element {
        e.common_mut().name = Some(name.to_string());
        e
    }

    fn layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            children: children.into_iter().map(Rc::new).collect(),
            common: CommonProps { name: Some(name.into()), ..Default::default() },
            isolated_blending: false,
            knockout_group: false,
        })
    }

    fn r(name: &str) -> Element {
        named(rect(0.0, 0.0, 1.0, 1.0), name)
    }

    fn g(name: &str, children: Vec<Element>) -> Element {
        named(group(children), name)
    }

    /// L1[a, G[b, c], d], L2[e]
    fn doc() -> Document {
        Document {
            layers: vec![
                layer("L1", vec![r("a"), g("G", vec![r("b"), r("c")]), r("d")]),
                layer("L2", vec![r("e")]),
            ],
            selected_layer: 0,
            selection: Vec::new(),
            ..Document::default()
        }
    }

    fn model_of(d: Document) -> Model {
        let mut m = Model::default();
        m.set_document_for_test(d);
        m
    }

    /// The tree as nested names, e.g. `L1[a G[b c] d] L2[e]`.
    fn tree(d: &Document) -> String {
        fn walk(e: &Element) -> String {
            let n = e.common().name.clone().unwrap_or_default();
            match e.children() {
                Some(kids) => format!("{n}[{}]", kids.iter().map(|k| walk(k)).collect::<Vec<_>>().join(" ")),
                None => n,
            }
        }
        d.layers.iter().map(walk).collect::<Vec<_>>().join(" ")
    }

    fn name_at(d: &Document, p: &[usize]) -> String {
        d.get_element(&p.to_vec()).and_then(|e| e.common().name.clone()).unwrap_or_default()
    }

    fn mv(m: &mut Model, paths: serde_json::Value, parent: serde_json::Value, index: usize) -> Result<(), OpError> {
        m.with_txn(|m| {
            op_apply(m, &json!({"op": "move_elements", "paths": paths, "target_parent": parent, "index": index}))
        })
    }

    #[test]
    fn leaf_into_a_group_lands_at_the_index_after_removal() {
        let d = doc();
        // `a` into G as its topmost child. G is [0,1]; after removing `a` it is
        // [0,0], and its child count after removal is 2.
        let plan = plan_move(&d, &[vec![0, 0]], &vec![0, 1], 2, &MoveContext::default()).unwrap();
        assert_eq!(plan.parent_after_removal, vec![0, 0]);
        let out = plan.apply(&d);
        assert_eq!(tree(&out), "L1[G[b c a] d] L2[e]");
    }

    #[test]
    fn op_moves_a_leaf_into_a_group() {
        let mut m = model_of(doc());
        mv(&mut m, json!([[0, 0]]), json!([0, 1]), 2).unwrap();
        assert_eq!(tree(m.document()), "L1[G[b c a] d] L2[e]");
    }

    #[test]
    fn index_counts_document_order_from_the_bottom() {
        let mut m = model_of(doc());
        // `d` to the bottom of L1.
        mv(&mut m, json!([[0, 2]]), json!([0]), 0).unwrap();
        assert_eq!(tree(m.document()), "L1[d a G[b c]] L2[e]");
    }

    #[test]
    fn multiple_elements_keep_their_document_order() {
        let mut m = model_of(doc());
        // `d` and `a` (given out of order) into L2 above `e`.
        mv(&mut m, json!([[0, 2], [0, 0]]), json!([1]), 1).unwrap();
        assert_eq!(tree(m.document()), "L1[G[b c]] L2[e a d]");
    }

    #[test]
    fn elements_from_different_parents_move_together() {
        let mut m = model_of(doc());
        // `b` (in G) and `e` (in L2) to L1's bottom.
        mv(&mut m, json!([[0, 1, 0], [1, 0]]), json!([0]), 0).unwrap();
        assert_eq!(tree(m.document()), "L1[b e a G[c] d] L2[]");
    }

    #[test]
    fn a_group_into_another_layer_and_a_layer_to_the_root() {
        let mut m = model_of(doc());
        mv(&mut m, json!([[0, 1]]), json!([1]), 0).unwrap();
        assert_eq!(tree(m.document()), "L1[a d] L2[G[b c] e]");
        // L1 above L2 at the root (root count after removal: 1).
        mv(&mut m, json!([[0]]), json!([]), 1).unwrap();
        assert_eq!(tree(m.document()), "L2[G[b c] e] L1[a d]");
    }

    #[test]
    fn a_layer_may_nest_in_a_layer() {
        let mut m = model_of(doc());
        mv(&mut m, json!([[1]]), json!([0]), 3).unwrap();
        assert_eq!(tree(m.document()), "L1[a G[b c] d L2[e]]");
    }

    #[test]
    fn refusals_by_rule() {
        let d = doc();
        let none = MoveContext::default();
        let refused = |paths: &[ElementPath], parent: ElementPath, ctx: &MoveContext| {
            match plan_move(&d, paths, &parent, 0, ctx) {
                Err(MoveError::Refused(r)) => r,
                other => panic!("expected a refusal, got {other:?}"),
            }
        };
        // Rule 1: into itself, and into its own descendant.
        assert_eq!(refused(&[vec![0, 1]], vec![0, 1], &none), MoveRefusal::IntoItselfOrDescendant);
        assert_eq!(refused(&[vec![0]], vec![0, 1], &none), MoveRefusal::IntoItselfOrDescendant);
        // Rule 3: a layer into a group; a leaf to the root; anything into a leaf.
        assert_eq!(refused(&[vec![1]], vec![0, 1], &none), MoveRefusal::WrongParentKind);
        assert_eq!(refused(&[vec![0, 0]], vec![], &none), MoveRefusal::WrongParentKind);
        assert_eq!(refused(&[vec![0, 0]], vec![0, 2], &none), MoveRefusal::WrongParentKind);
        // Rule 4: while filtering.
        let filtering = MoveContext { filtering: true, ..Default::default() };
        assert_eq!(refused(&[vec![0, 0]], vec![1], &filtering), MoveRefusal::FilterActive);
        // Rule 5: isolated in G, a drop into L2 is outside; into G itself is fine.
        let iso = MoveContext { isolation_stack: vec![vec![0], vec![0, 1]], ..Default::default() };
        assert_eq!(refused(&[vec![0, 1, 0]], vec![1], &iso), MoveRefusal::OutsideIsolation);
        assert!(drop_valid(&d, &[vec![0, 1, 0]], &vec![0, 1], 0, &iso));
    }

    /// ERRATUM 1: the names are exactly the spec's.
    #[test]
    fn refusal_names_are_the_specs() {
        let names: Vec<&str> = [
            MoveRefusal::IntoItselfOrDescendant,
            MoveRefusal::LockedParent,
            MoveRefusal::WrongParentKind,
            MoveRefusal::FilterActive,
            MoveRefusal::OutsideIsolation,
        ]
        .iter()
        .map(|r| r.name())
        .collect();
        assert_eq!(names, vec!["into_itself_or_descendant", "locked_parent", "wrong_parent_kind",
                               "filter_active", "outside_isolation"]);
    }

    /// ERRATUM 1: the check returns the FIRST failure: rules in the order
    /// listed, for the dragged elements in document order.
    #[test]
    fn the_first_failure_is_returned() {
        let mut d = doc();
        // G ([0,1]) locked: into G fails rules 1, 2 (and 3 for a layer).
        d.get_element_mut(&vec![0, 1]).unwrap().common_mut().locked = true;
        let all = MoveContext { filtering: true, isolation_stack: vec![vec![1]] };
        let first = |paths: &[ElementPath], parent: ElementPath| match plan_move(&d, paths, &parent, 0, &all) {
            Err(MoveError::Refused(r)) => r.name(),
            other => panic!("expected a refusal, got {other:?}"),
        };
        // L1 into its own child G: fails all five; rule 1 is reported.
        assert_eq!(first(&[vec![0]], vec![0, 1]), "into_itself_or_descendant");
        // `a` into the locked G (also filtering, outside isolation): rule 2.
        assert_eq!(first(&[vec![0, 0]], vec![0, 1]), "locked_parent");
        // `a` to the root (also filtering, outside isolation): rule 3.
        assert_eq!(first(&[vec![0, 0]], vec![]), "wrong_parent_kind");
        // `a` into L1 (also outside isolation): rule 4.
        assert_eq!(first(&[vec![0, 0]], vec![0]), "filter_active");
        // Document order: `a` ([0,0], to the root: rule 3) is checked before
        // L2 ([1], to the root: valid), whatever order the paths are given in.
        assert_eq!(first(&[vec![1], vec![0, 0]], vec![]), "wrong_parent_kind");
        // `e` into L1, isolated in L2 only: rule 5.
        let iso = MoveContext { filtering: false, isolation_stack: vec![vec![1]] };
        assert_eq!(plan_move(&d, &[vec![1, 0]], &vec![0], 0, &iso),
                   Err(MoveError::Refused(MoveRefusal::OutsideIsolation)));
        assert_eq!(MoveRefusal::OutsideIsolation.name(), "outside_isolation");
    }

    /// ERRATUM 1: a refused move SUCCEEDS with nothing changed, nothing
    /// journaled and no undo step, also under the action's own `snapshot`.
    #[test]
    fn a_refused_move_under_the_actions_snapshot_leaves_no_trace() {
        let mut m = model_of(doc());
        let journal = m.journal_head();
        op_apply(&mut m, &json!({"op": "snapshot"})).unwrap();
        let r = op_apply(&mut m, &json!({"op": "move_elements", "paths": [[0]], "target_parent": [0, 1],
                                         "index": 0}));
        m.commit_txn();
        assert_eq!(r, Ok(()));
        assert_eq!(tree(m.document()), tree(&doc()));
        assert_eq!(m.journal_head(), journal, "nothing journaled");
        assert!(!m.can_undo(), "no undo step");
    }

    #[test]
    fn a_locked_parent_or_ancestor_refuses_but_a_locked_dragged_element_moves() {
        let mut d = doc();
        d.layers[1].common_mut().locked = true;
        let none = MoveContext::default();
        assert_eq!(plan_move(&d, &[vec![0, 0]], &vec![1], 0, &none),
                   Err(MoveError::Refused(MoveRefusal::LockedParent)));
        // Lock inherited: G inside a locked L1.
        let mut d2 = doc();
        d2.layers[0].common_mut().locked = true;
        assert_eq!(plan_move(&d2, &[vec![1, 0]], &vec![0, 1], 0, &none),
                   Err(MoveError::Refused(MoveRefusal::LockedParent)));
        // A locked dragged element is allowed.
        let mut d3 = doc();
        d3.get_element_mut(&vec![0, 0]).unwrap().common_mut().locked = true;
        assert!(drop_valid(&d3, &[vec![0, 0]], &vec![1], 0, &none));
    }

    #[test]
    fn one_invalid_element_refuses_the_whole_drop_and_nothing_changes() {
        let mut m = model_of(doc());
        let before = tree(m.document());
        let generation = m.generation();
        // `a` could go to the root? no — but L2 could; the leaf fails rule 3.
        let r = mv(&mut m, json!([[1], [0, 0]]), json!([]), 0);
        assert_eq!(r, Ok(()), "a rule refusal is Ok with nothing changed");
        assert_eq!(tree(m.document()), before);
        assert_eq!(m.generation(), generation, "nothing was written");
        assert!(!m.can_undo(), "and no undo step was taken");
    }

    #[test]
    fn filtering_and_isolation_reach_the_op_through_its_params() {
        let mut m = model_of(doc());
        let before = tree(m.document());
        m.with_txn(|m| op_apply(m, &json!({"op": "move_elements", "paths": [[0, 0]], "target_parent": [1],
                                           "index": 0, "search_query": "x"}))).unwrap();
        assert_eq!(tree(m.document()), before, "a search refuses");
        m.with_txn(|m| op_apply(m, &json!({"op": "move_elements", "paths": [[0, 0]], "target_parent": [1],
                                           "index": 0, "type_filter": ["rectangle"]}))).unwrap();
        assert_eq!(tree(m.document()), before, "a type filter refuses");
        // The model's own isolation stack is the fallback.
        m.isolation_stack = vec![vec![0, 1]];
        mv(&mut m, json!([[0, 0]]), json!([1]), 0).unwrap();
        assert_eq!(tree(m.document()), before, "outside the model's isolation refuses");
        // An explicit isolation_stack in the op wins (markers accepted).
        m.with_txn(|m| op_apply(m, &json!({"op": "move_elements", "paths": [{"__path__": [0, 0]}],
                                           "target_parent": {"__path__": [0, 1]}, "index": 0,
                                           "isolation_stack": [{"__path__": [0, 1]}]}))).unwrap();
        assert_eq!(tree(m.document()), "L1[G[a b c] d] L2[e]");
        assert_eq!(m.isolation_stack, vec![vec![0, 0]], "the model's isolation stack is remapped");
    }

    #[test]
    fn param_faults_and_missing_targets_err() {
        let mut m = model_of(doc());
        assert!(matches!(op_apply(&mut m, &json!({"op": "move_elements"})), Err(OpError::MissingParam { .. })));
        assert!(matches!(mv(&mut m, json!([[9]]), json!([0]), 0), Err(OpError::MissingTarget { .. })));
        assert!(matches!(mv(&mut m, json!([[0, 0]]), json!([0, 9]), 0), Err(OpError::MissingTarget { .. })));
        assert!(matches!(mv(&mut m, json!([[0, 0]]), json!([1]), 5), Err(OpError::BadParamType { name: "index" })));
        assert!(matches!(m.with_txn(|m| op_apply(m, &json!({"op": "move_elements", "paths": [[0, 0]],
            "target_parent": [1], "index": -1}))), Err(OpError::BadParamType { name: "index" })));
        assert_eq!(mv(&mut m, json!([]), json!([1]), 0), Ok(()), "nothing to move is a benign no-op");
        assert_eq!(tree(m.document()), tree(&doc()));
    }

    #[test]
    fn a_float_index_from_the_expression_layer_is_read() {
        let mut m = model_of(doc());
        m.with_txn(|m| op_apply(m, &json!({"op": "move_elements", "paths": [[0, 0]], "target_parent": [1],
                                           "index": 1.0}))).unwrap();
        assert_eq!(tree(m.document()), "L1[G[b c] d] L2[e a]");
    }

    #[test]
    fn a_drop_is_one_undo_step() {
        let mut m = model_of(doc());
        // The action's own `snapshot`, then the op, then the batch commit.
        op_apply(&mut m, &json!({"op": "snapshot"})).unwrap();
        op_apply(&mut m, &json!({"op": "move_elements", "paths": [[0, 0], [1, 0]], "target_parent": [0, 1],
                                 "index": 0})).unwrap();
        m.commit_txn();
        assert_eq!(tree(m.document()), "L1[G[a e b c] d] L2[]");
        m.undo();
        assert_eq!(tree(m.document()), tree(&doc()), "one undo restores the whole drop");
        assert!(!m.can_undo(), "the drop was exactly one step");
    }

    #[test]
    fn remap_follows_every_element() {
        let d = doc();
        // `a` and `e` into G's bottom.
        let plan = plan_move(&d, &[vec![0, 0], vec![1, 0]], &vec![0, 1], 0, &MoveContext::default()).unwrap();
        let out = plan.apply(&d);
        for p in [vec![0], vec![1], vec![0, 0], vec![0, 1], vec![0, 1, 0], vec![0, 1, 1], vec![0, 2], vec![1, 0]] {
            assert_eq!(name_at(&out, &plan.remap(&p)), name_at(&d, &p), "{p:?} -> {:?}", plan.remap(&p));
        }
        assert_eq!(plan.remap(&[]), Vec::<usize>::new(), "the root is the root");
    }

    #[test]
    fn a_descendant_of_a_dragged_element_rides_along() {
        let d = doc();
        let plan = plan_move(&d, &[vec![0, 1], vec![0, 1, 0]], &vec![1], 1, &MoveContext::default()).unwrap();
        assert_eq!(plan.moved, vec![vec![0, 1]]);
        let out = plan.apply(&d);
        assert_eq!(tree(&out), "L1[a d] L2[e G[b c]]");
        assert_eq!(plan.remap(&[0, 1, 0]), vec![1, 1, 0]);
    }

    /// ERRATUM 3: the rules are checked for the ROOTS only. L1 with its own
    /// leaf `a` to the root: `a` alone would fail rule 3 (a leaf never goes
    /// to the root), but it is not a root, so it is never checked and the
    /// drop is valid; `a` stays inside L1.
    #[test]
    fn a_non_root_is_never_checked_against_the_rules() {
        let d = doc();
        let none = MoveContext::default();
        assert_eq!(plan_move(&d, &[vec![0, 0]], &vec![], 0, &none),
                   Err(MoveError::Refused(MoveRefusal::WrongParentKind)), "alone, `a` is refused");
        let mut m = model_of(doc());
        mv(&mut m, json!([[0, 0], [0]]), json!([]), 1).unwrap();
        assert_eq!(tree(m.document()), "L2[e] L1[a G[b c] d]");
    }

    /// ERRATUM 3: the first failure is a ROOT's. L1 (with its child G's leaf
    /// `b`) into G: the root L1 fails rule 1 and that name is returned.
    #[test]
    fn the_first_failure_is_a_roots() {
        let d = doc();
        assert_eq!(plan_move(&d, &[vec![0, 1, 0], vec![0]], &vec![0, 1], 0, &MoveContext::default()),
                   Err(MoveError::Refused(MoveRefusal::IntoItselfOrDescendant)));
    }

    /// ERRATUM 3: `index` counts the target parent's children that are NOT
    /// being moved; a non-root inside a moved root is not one of them.
    #[test]
    fn the_index_counts_the_parents_non_moved_children() {
        let d = doc();
        let none = MoveContext::default();
        // G and its own `c` within L1: L1's non-moved children are a and d.
        let plan = plan_move(&d, &[vec![0, 1], vec![0, 1, 1]], &vec![0], 2, &none).unwrap();
        assert_eq!(tree(&plan.apply(&d)), "L1[a d G[b c]] L2[e]");
        assert_eq!(plan_move(&d, &[vec![0, 1], vec![0, 1, 1]], &vec![0], 3, &none),
                   Err(MoveError::IndexOutOfRange));
    }

    /// ERRATUM 3: roots go in DOCUMENT order whatever order the paths are
    /// given in, and every selected element — roots and the descendants that
    /// travelled inside them — is followed by identity.
    #[test]
    fn roots_keep_document_order_and_every_selected_element_is_followed() {
        let d = doc();
        let given = [vec![0, 1, 1], vec![0, 1], vec![0, 0]];
        let plan = plan_move(&d, &given, &vec![1], 1, &MoveContext::default()).unwrap();
        assert_eq!(plan.moved, vec![vec![0, 0], vec![0, 1]]);
        let out = plan.apply(&d);
        assert_eq!(tree(&out), "L1[d] L2[e a G[b c]]");
        for p in &given {
            assert_eq!(name_at(&out, &plan.remap(p)), name_at(&d, p), "{p:?}");
        }
        assert_eq!(plan.remap(&[0, 1, 1]), vec![1, 2, 1], "`c` keeps its path within G");
    }

    /// A missing element stays an error (spec §3), a non-root as much as a
    /// root: the reduction confines the RULES to the roots, not the operand
    /// check.
    #[test]
    fn a_missing_non_root_is_still_a_missing_target() {
        let d = doc();
        assert_eq!(plan_move(&d, &[vec![0, 1], vec![0, 1, 9]], &vec![1], 0, &MoveContext::default()),
                   Err(MoveError::MissingTarget(vec![0, 1, 9])));
    }

    /// ERRATUM 3 through the `doc.op` effect: the panel selection becomes the
    /// new paths of EVERY selected element, the descendant included.
    #[test]
    fn the_panel_selection_follows_a_root_and_its_selected_descendant() {
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        let mut scope = std::collections::HashMap::new();
        scope.insert("search_query".to_string(), json!(""));
        scope.insert("type_filter".to_string(), json!([]));
        scope.insert("isolation_stack".to_string(), json!([]));
        scope.insert("layers_panel_selection".to_string(),
                     json!([{"__path__": [0, 1]}, {"__path__": [0, 1, 0]}]));
        scope.insert("collapsed_paths".to_string(), json!([]));
        scope.insert("renaming_element".to_string(), json!(null));
        scope.insert("solo_path".to_string(), json!(null));
        scope.insert("solo_saved".to_string(), json!([]));
        let mut store = StateStore::new();
        store.init_panel("layers", scope);
        let effect = json!({"doc.op": {"op": "move_elements", "paths": "param.paths",
                                       "target_parent": "param.target_parent", "index": "param.index"}});
        let ctx = json!({"param": {"paths": [{"__path__": [0, 1]}, {"__path__": [0, 1, 0]}],
                                   "target_parent": {"__path__": [1]}, "index": 1}});
        let mut m = model_of(doc());
        let report = run_effects(&[effect], &ctx, &mut store, Some(&mut m), None, None, None);
        assert!(report.unhandled.is_empty(), "{:?}", report.unhandled);
        assert_eq!(tree(m.document()), "L1[a d] L2[e G[b c]]");
        assert_eq!(store.get_panel("layers", "layers_panel_selection"),
                   &json!([{"__path__": [1, 1]}, {"__path__": [1, 1, 0]}]));
    }

    #[test]
    fn the_document_selection_and_target_layer_follow_the_move() {
        let mut d = doc();
        d.selection = vec![ElementSelection::all(vec![0, 2]), ElementSelection::all(vec![1, 0])];
        d.selected_layer = 1;
        let mut m = model_of(d);
        // L2 to the root bottom.
        mv(&mut m, json!([[1]]), json!([]), 0).unwrap();
        let out = m.document();
        assert_eq!(tree(out), "L2[e] L1[a G[b c] d]");
        let names: Vec<String> = out.selection.iter().map(|es| name_at(out, &es.path)).collect();
        assert_eq!(names, vec!["d", "e"]);
        assert_eq!(out.selected_layer, 0, "the target layer is still L2");
    }

    #[test]
    fn panel_values_are_remapped_in_their_stored_form() {
        let d = doc();
        // `a` into L2 at the bottom: G and d shift up in L1.
        let plan = plan_move(&d, &[vec![0, 0]], &vec![1], 0, &MoveContext::default()).unwrap();
        // collapsed_paths: G (a later sibling) shifts though it did not move.
        assert_eq!(plan.remap_panel_value("collapsed_paths", &json!([{"__path__": [0, 1]}, {"__path__": [1]}])),
                   json!([{"__path__": [0, 0]}, {"__path__": [1]}]));
        assert_eq!(plan.remap_panel_value("renaming_element", &json!([0, 2])), json!([0, 1]));
        assert_eq!(plan.remap_panel_value("renaming_element", &json!(null)), json!(null));
        assert_eq!(plan.remap_panel_value("solo_path", &json!([0, 0])), json!([1, 0]));
        assert_eq!(plan.remap_panel_value("solo_saved", &json!([[[0, 1], "preview"], [[0, 2], "outline"]])),
                   json!([[[0, 0], "preview"], [[0, 1], "outline"]]));
        assert_eq!(plan.remap_panel_value("isolation_stack", &json!([{"__path__": [0, 1]}, {"container_id": "x"}])),
                   json!([{"__path__": [0, 0]}, {"container_id": "x"}]));
        // An insertion shifts later siblings too: e is now above a.
        assert_eq!(plan.remap_panel_value("collapsed_paths", &json!([[1, 0]])), json!([[1, 1]]));
    }

    /// Through the `doc.op` effect, as the `move_elements` action runs it: the
    /// panel's filter state reaches the rules, and after a move every path the
    /// Layers panel stores is remapped and the panel selection is the moved
    /// elements' new paths.
    #[test]
    fn the_doc_op_effect_remaps_every_stored_panel_path() {
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        let seed = |search: &str| {
            let mut scope = std::collections::HashMap::new();
            scope.insert("search_query".to_string(), json!(search));
            scope.insert("type_filter".to_string(), json!([]));
            scope.insert("isolation_stack".to_string(), json!([]));
            scope.insert("layers_panel_selection".to_string(), json!([{"__path__": [0, 0]}]));
            scope.insert("collapsed_paths".to_string(), json!([{"__path__": [0, 1]}, {"__path__": [1]}]));
            scope.insert("renaming_element".to_string(), json!(null));
            scope.insert("solo_path".to_string(), json!([0, 2]));
            scope.insert("solo_saved".to_string(), json!([]));
            let mut store = StateStore::new();
            store.init_panel("layers", scope);
            store
        };
        let effect = json!({"doc.op": {"op": "move_elements", "paths": "param.paths",
                                       "target_parent": "param.target_parent", "index": "param.index"}});
        let ctx = json!({"param": {"paths": [{"__path__": [0, 0]}], "target_parent": {"__path__": [1]}, "index": 0}});

        // While searching, the drop is refused and nothing moves.
        let mut store = seed("b");
        let mut m = model_of(doc());
        let report = run_effects(&[effect.clone()], &ctx, &mut store, Some(&mut m), None, None, None);
        assert!(report.unhandled.is_empty(), "{:?}", report.unhandled);
        assert_eq!(tree(m.document()), tree(&doc()));
        assert_eq!(store.get_panel("layers", "collapsed_paths"), &json!([{"__path__": [0, 1]}, {"__path__": [1]}]));

        // No search: `a` moves to the bottom of L2.
        let mut store = seed("");
        let mut m = model_of(doc());
        let report = run_effects(&[effect], &ctx, &mut store, Some(&mut m), None, None, None);
        assert!(report.unhandled.is_empty(), "{:?}", report.unhandled);
        assert_eq!(tree(m.document()), "L1[G[b c] d] L2[a e]");
        assert_eq!(store.get_panel("layers", "layers_panel_selection"), &json!([{"__path__": [1, 0]}]));
        assert_eq!(store.get_panel("layers", "collapsed_paths"), &json!([{"__path__": [0, 0]}, {"__path__": [1]}]),
                   "G shifted up though it did not move");
        assert_eq!(store.get_panel("layers", "solo_path"), &json!([0, 1]));
        assert_eq!(store.get_panel("layers", "renaming_element"), &json!(null));
    }

    #[test]
    fn a_path_below_a_leaf_names_nothing() {
        // [0, 0, 0] would be a child of `a`, a leaf.
        let d = doc();
        assert!(matches!(plan_move(&d, &[vec![0, 0, 0]], &vec![1], 0, &MoveContext::default()),
                         Err(MoveError::MissingTarget(_))));
    }
}
