import AppKit
import Foundation
import TilerCore

/// Everything an undo step restores (decision T41). Export settings are deliberately excluded.
struct EditState: Equatable {
    var crop: CropState
    var quarterTurns: QuarterTurns
    var aspectPreset: AspectPreset
    var customAspect: AspectRatio
    var tileCount: Int
}

/// An interaction (or coalesced burst) whose undo step has not been registered yet.
struct PendingEdit {
    var start: EditState
    var name: String
    /// Auto-commits after `AppModel.coalesceInterval` of quiet instead of waiting for `endEdit`.
    var coalesced: Bool
}

/// Undo / redo for editing changes.
///
/// One user interaction = one undo step. The canvas, the inspector sliders and the discrete
/// actions (turns, reset, tile count, aspect) all funnel through `beginEdit`/`endEdit`,
/// `performEdit` or `discreteEdit`, which compare the `EditState` before and after and register
/// one `UndoManager` step with the snapshot to go back to. Undoing registers the redo the same
/// way (`restore`), under the `isApplyingEdit` guard so nothing double-registers.
extension AppModel {
    /// Quiet time after which a burst of tiny inputs (custom aspect typing) becomes one step.
    static let coalesceInterval: Duration = .milliseconds(500)

    // MARK: Snapshots

    var editState: EditState {
        EditState(crop: crop, quarterTurns: quarterTurns, aspectPreset: aspectPreset,
                  customAspect: customAspect, tileCount: tileCount)
    }

    /// The current snapshot with one spec field swapped for its previous value (used from the
    /// `didSet` observers, where the new value is already stored).
    func editState(preset: AspectPreset? = nil, custom: AspectRatio? = nil, count: Int? = nil) -> EditState {
        var s = editState
        if let preset { s.aspectPreset = preset }
        if let custom { s.customAspect = custom }
        if let count { s.tileCount = count }
        return s
    }

    // MARK: Interactions

    /// Starts an interaction (drag, slider drag, gesture). Anything still pending is committed
    /// first. Pair with `endEdit(actionName:)`; nothing is registered if the state is unchanged.
    func beginEdit(_ actionName: String = "Edit") {
        guard hasImage, !isApplyingEdit else { return }
        commitPendingEdit()
        pendingEdit = PendingEdit(start: editState, name: actionName, coalesced: false)
    }

    /// Ends the interaction started by `beginEdit` and registers one undo step if anything
    /// changed. A no-op when nothing is pending (e.g. a discrete edit already committed it).
    func endEdit(actionName: String? = nil) {
        guard var p = pendingEdit else { return }
        if let actionName { p.name = actionName }
        pendingEdit = nil
        coalesceGeneration += 1
        registerEdit(from: p.start, to: editState, actionName: p.name)
    }

    /// Runs `body` as one undo step, unless an interaction is open (a slider drag), in which
    /// case the interaction's `endEdit` records it.
    func performEdit(_ actionName: String, _ body: () -> Void) {
        if let p = pendingEdit, !p.coalesced { body(); return }
        discreteEdit(actionName, body)
    }

    /// One self-contained step: snapshot, change, register.
    func discreteEdit(_ actionName: String, _ body: () -> Void) {
        guard hasImage, !isApplyingEdit else { body(); return }
        let before = editState
        commitPendingEdit(endingAt: before)
        body()
        registerEdit(from: before, to: editState, actionName: actionName)
    }

    /// Opens (or extends) a coalesced step that commits after `coalesceInterval` of quiet.
    func beginCoalescedEdit(_ actionName: String, from start: EditState) {
        if let p = pendingEdit, p.coalesced, p.name == actionName {
            // Keep the original start.
        } else {
            commitPendingEdit(endingAt: start)
            pendingEdit = PendingEdit(start: start, name: actionName, coalesced: true)
        }
        coalesceGeneration += 1
        let generation = coalesceGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesceInterval)
            guard let self, generation == self.coalesceGeneration else { return }
            self.commitPendingEdit()
        }
    }

    /// Registers whatever is pending, ending at `state` (default: the current state).
    func commitPendingEdit(endingAt state: EditState? = nil) {
        guard let p = pendingEdit else { return }
        pendingEdit = nil
        coalesceGeneration += 1
        registerEdit(from: p.start, to: state ?? editState, actionName: p.name)
    }

    // MARK: Registration

    func registerEdit(from before: EditState, to after: EditState, actionName: String) {
        guard hasImage, !isApplyingEdit, before != after else { return }
        undoManager.beginUndoGrouping()
        registerStep(restoring: before, counterpart: after, actionName: actionName)
        undoManager.endUndoGrouping()
        refreshUndoState()
    }

    /// Registers "go to `state`"; when run it registers the reverse (redo / undo again).
    private func registerStep(restoring state: EditState, counterpart: EditState, actionName: String) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.apply(state)
                model.registerStep(restoring: counterpart, counterpart: state, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func apply(_ s: EditState) {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        quarterTurns = s.quarterTurns
        aspectPreset = s.aspectPreset
        customAspect = s.customAspect
        tileCount = s.tileCount
        // Last, and verbatim: the snapshot was already valid for this spec.
        crop = s.crop
    }

    // MARK: Menu commands

    func undo() {
        commitPendingEdit()
        guard undoManager.canUndo else { return }
        undoManager.undo()
        refreshUndoState()
    }

    func redo() {
        commitPendingEdit()
        guard undoManager.canRedo else { return }
        undoManager.redo()
        refreshUndoState()
    }

    /// Opening a new image starts a fresh history.
    func clearUndoHistory() {
        pendingEdit = nil
        coalesceGeneration += 1
        undoManager.removeAllActions()
        refreshUndoState()
    }

    func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoMenuTitle = undoManager.canUndo ? undoManager.undoMenuItemTitle : "Undo"
        redoMenuTitle = undoManager.canRedo ? undoManager.redoMenuItemTitle : "Redo"
    }
}

// MARK: Edit menu

import SwiftUI

/// The Edit menu's Undo / Redo items, driven by the model's own `UndoManager`. A separate
/// `Commands` value so SwiftUI tracks the model's observable state (titles, enablement).
struct UndoCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoMenuTitle) { model.undoFromMenu() }
                .keyboardShortcut("z", modifiers: .command)
            Button(model.redoMenuTitle) { model.redoFromMenu() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

extension AppModel {
    /// ⌘Z. While a text field is being edited and has its own text history, that wins.
    func undoFromMenu() {
        if let um = Self.fieldEditorUndoManager(), um.canUndo { um.undo(); return }
        undo()
    }

    /// ⇧⌘Z.
    func redoFromMenu() {
        if let um = Self.fieldEditorUndoManager(), um.canRedo { um.redo(); return }
        redo()
    }

    private static func fieldEditorUndoManager() -> UndoManager? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isFieldEditor,
              let um = text.undoManager, um !== AppModel.shared.undoManager else { return nil }
        return um
    }
}
