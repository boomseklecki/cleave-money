import SwiftUI

/// Splitwise-style phrasing for a net balance - "you owe $X" / "you are owed $X" instead of a signed
/// amount. Convention: `net > 0` means this person is owed money (green); `net < 0` means they owe
/// (red); `0` is settled. Colors are consistent everywhere a balance is shown.
enum BalancePhrase {
    struct Display {
        let label: String
        let amount: String?
        let color: Color
    }

    /// Your own net (the Splits tab and your row in a group).
    static func mine(_ net: Decimal, code: String = "USD") -> Display {
        member(net, isMe: true, code: code)
    }

    /// A group member's net; `isMe` switches to first-person phrasing.
    static func member(_ net: Decimal, isMe: Bool, code: String = "USD") -> Display {
        if net == 0 { return Display(label: "settled up", amount: nil, color: .gray) }
        let amount = abs(net).formatted(.currency(code: code))
        if net > 0 {
            return Display(label: isMe ? "you are owed" : "gets back", amount: amount, color: .green)
        }
        return Display(label: isMe ? "you owe" : "owes", amount: amount, color: .red)
    }
}
