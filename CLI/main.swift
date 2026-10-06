import EarmarkCLI
import Foundation

// Только точка входа: логика в EarmarkCLI, чтобы её гонял `swift test`.
exit(await EarmarkCLI.run(Array(CommandLine.arguments.dropFirst())))
