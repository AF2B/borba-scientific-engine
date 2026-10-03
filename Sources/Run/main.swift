import BorbaScientificEngine
import Foundation

exit(
    await Entrypoint.run(
        environment: ProcessInfo.processInfo.environment,
        arguments: CommandLine.arguments
    )
)
