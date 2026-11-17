import Foundation

/// The stepping of the arrow keys through an open list, as the key managers of the reference
/// do it: to the next or the previous entry that can be chosen, and round at the ends.
public enum KeyboardList {
    /// The entry after a step of +1 or -1 from `current`. Without a current entry the first
    /// one is taken for a step down and the last one for a step up. nil when nothing can be chosen.
    public static func step(from current: Int?, by step: Int, canChoose: [Bool]) -> Int? {
        let choices = canChoose.indices.filter { canChoose[$0] }
        guard !choices.isEmpty, step != 0 else { return current }
        guard let current, let place = choices.firstIndex(of: current) else {
            // An entry that cannot be chosen, or none: the nearest one in the direction of the step.
            if let current {
                return step > 0 ? (choices.first { $0 > current } ?? choices.first) : (choices.last { $0 < current } ?? choices.last)
            }
            return step > 0 ? choices.first : choices.last
        }
        let next = (place + (step > 0 ? 1 : -1) + choices.count) % choices.count
        return choices[next]
    }
}
