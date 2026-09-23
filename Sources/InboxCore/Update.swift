import Foundation
import MobiusCore

/// Mobius `Update` for the app. It wraps `InboxReducer.reduce`, which remains the single place
/// where state transitions and their effects are defined.
public enum InboxUpdate {
    /// The update as a Mobius `Update` value, for `Mobius.loop` and `UpdateSpec`.
    public static var update: Update<InboxModel, Event, InboxEffect> { Update(update(model:event:)) }

    public static func update(model: InboxModel, event: Event) -> Next<InboxModel, InboxEffect> {
        do {
            let step = try InboxReducer.reduce(model, event)
            // An unchanged model is reported as "no model" so observers (and tests) only see real changes.
            return step.model == model ? .dispatchEffects(step.effects) : .next(step.model, effects: step.effects)
        } catch {
            return .dispatchEffects([.reject(error)])
        }
    }
}
