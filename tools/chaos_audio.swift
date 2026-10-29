// Exhaustive sweep of the audio codec contract against the real
// AudioNegotiation.resolve, not a transcription of it.
//
//   swiftc -o /tmp/chaos_audio tools/chaos_audio.swift \
//       mac/Sources/AirScreen/AudioWire.swift mac/Sources/AirScreen/StreamSettings.swift
//
// The rule under test, stated independently of the implementation (from
// protocol/protocol.md and the README): the Mac never sends a codec the TV has
// not advertised, and a TV that says nothing about audio gets PCM.
import Foundation

@main
enum ChaosAudio {
static func main() {
let choices: [AudioChoice] = AudioChoice.allCases
let offerings: [(label: String, value: [String]?)] = [
    ("nil", nil),
    ("[]", []),
    ("[pcm16]", ["pcm16"]),
    ("[opus]", ["opus"]),
    ("[opus,pcm16]", ["opus", "pcm16"]),
    ("[OPUS]", ["OPUS"]),            // case must not matter
    ("[Opus ]", ["Opus "]),          // stray whitespace must not match
    ("[vorbis]", ["vorbis"]),
    ("[pcm16,vorbis]", ["pcm16", "vorbis"]),
]
let encoderStates = [true, false]

var failures: [String] = []
var opusCount = 0
var rows = 0

func check(_ ok: Bool, _ message: String) {
    if !ok { failures.append(message) }
}


print("choice      offered          encoder  ->  wire")
print("-----------------------------------------------")
for choice in choices {
    for offering in offerings {
        for encoder in encoderStates {
            let result = AudioNegotiation.resolve(
                choice: choice, offered: offering.value, encoderAvailable: encoder
            )
            rows += 1
            if result == .opus { opusCount += 1 }
            print(String(format: "%-11@ %-16@ %-8@ ->  %@",
                         choice.rawValue as NSString,
                         offering.label as NSString,
                         (encoder ? "yes" : "no") as NSString,
                         result.wireName as NSString))

            let advertisedOpus = (offering.value ?? []).contains {
                $0.caseInsensitiveCompare("opus") == .orderedSame
            }
            let input = "\(choice.rawValue)/\(offering.label)/encoder=\(encoder)"

            // 1. Never encode with a codec this Mac cannot produce.
            check(!(result == .opus && !encoder),
                  "\(input): chose Opus with no encoder")
            // 2. Never send a codec the TV did not advertise.
            check(!(result == .opus && !advertisedOpus),
                  "\(input): chose Opus but the TV advertised \(offering.label)")
            // 3. An explicit PCM choice is always honoured.
            check(!(choice == .pcm16 && result != .pcm16),
                  "\(input): user asked for PCM and got \(result.wireName)")
            // 4. Silence about audio is never read as Opus support.
            check(!(offering.value == nil && result == .opus),
                  "\(input): treated an unspecified codec list as Opus")

            // Determinism.
            let again = AudioNegotiation.resolve(
                choice: choice, offered: offering.value, encoderAvailable: encoder
            )
            check(again == result, "\(input): not deterministic")
        }
    }
}

print("\n\(rows) combinations enumerated (full cross product)")
// Guard against a vacuously-passing sweep: if nothing ever selects Opus, every
// invariant above holds for an uninteresting reason.
check(opusCount > 0, "VACUOUS: no combination ever selected Opus")
print("combinations selecting Opus: \(opusCount)")

if failures.isEmpty {
    print("\nall invariants hold")
} else {
    print("\n\(failures.count) FAILURES:")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
}
}
