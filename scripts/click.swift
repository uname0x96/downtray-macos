// Posts a real click at screen coordinates (top-left origin), like a user's mouse.
// Needs Accessibility permission for the terminal that runs it.
//   swift scripts/click.swift <x> <y> [right]
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard args.count == 2 else { fputs("usage: click.swift <x> <y> [right]\n", stderr); exit(2) }
let right = CommandLine.arguments.last == "right"
let point = CGPoint(x: args[0], y: args[1])
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left)
let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left)
move?.post(tap: .cghidEventTap)
usleep(60_000)
down?.post(tap: .cghidEventTap)
usleep(60_000)
up?.post(tap: .cghidEventTap)
