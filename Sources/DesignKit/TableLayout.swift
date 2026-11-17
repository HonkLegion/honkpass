import CoreGraphics

/// The column widths of a table with "table-layout: auto", the layout of a `bit-table` unless
/// it says "fixed". The browser of the reference makes each column as wide as its content
/// and then deals with the width that is left over or missing.
public enum BWTableLayout {
    public struct Column: Sendable, Equatable {
        /// The width of the widest cell when its content breaks wherever it can.
        public var minimum: CGFloat
        /// The width of the widest cell when its content stays on one line.
        public var maximum: CGFloat
        /// A cell of the column has a width of its own ("tw-w-0"): the column takes no left over width.
        public var hasOwnWidth: Bool

        public init(minimum: CGFloat, maximum: CGFloat, hasOwnWidth: Bool = false) {
            self.minimum = min(minimum, maximum)
            self.maximum = maximum
            self.hasOwnWidth = hasOwnWidth
        }

        /// A column whose content does not break.
        public init(_ width: CGFloat, hasOwnWidth: Bool = false) {
            self.init(minimum: width, maximum: width, hasOwnWidth: hasOwnWidth)
        }
    }

    /// The widths of the columns of a table that is `width` wide.
    ///
    /// - Wider than its content: the left over width goes to the columns without a width of
    ///   their own, each in proportion to its content. Without such a column it goes to all.
    /// - Narrower than its content: each column gives up the same share of the width
    ///   between its content on one line and its content broken.
    /// - Narrower than its broken content: the columns keep that width and the table reaches out.
    public static func widths(of columns: [Column], in width: CGFloat) -> [CGFloat] {
        let maximum = columns.reduce(0) { $0 + $1.maximum }
        let minimum = columns.reduce(0) { $0 + $1.minimum }
        if width >= maximum {
            let extra = width - maximum
            let takers = columns.contains { !$0.hasOwnWidth } ? columns.map { !$0.hasOwnWidth } : columns.map { _ in true }
            let share = zip(columns, takers).reduce(0) { $0 + ($1.1 ? $1.0.maximum : 0) }
            guard share > 0 else { return columns.map(\.maximum) }
            return zip(columns, takers).map { column, takes in
                column.maximum + (takes ? extra * column.maximum / share : 0)
            }
        }
        guard width > minimum, maximum > minimum else { return columns.map(\.minimum) }
        let part = (width - minimum) / (maximum - minimum)
        return columns.map { $0.minimum + ($0.maximum - $0.minimum) * part }
    }
}
