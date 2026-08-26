public struct FocusCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .focus,
        help: focus_help_generated,
        flags: [
            "--ignore-floating": falseBoolFlag(\.floatingAsTiling),
            "--window-id": windowIdSubArgParser(),
            "--dfs-index": singleValueSubArgParser(\.dfsIndex, "<dfs-index>", parseUInt32),

            "--boundaries": ArgParser(\.rawBoundaries, upcastArgParserFun(parseBoundaries)),
            "--boundaries-action": ArgParser(\.rawBoundariesAction, upcastArgParserFun(parseBoundariesAction)),
            "--fail-if-fullscreen": trueBoolFlag(\.failIfFullscreen),
            "--fail-if-macos-native-fullscreen": trueBoolFlag(\.failIfMacosNativeFullscreen),
            "--wrap-around": trueBoolFlag(\.wrapAroundAlias),
        ],
        posArgs: [ArgParser(\.cardinalDfsOrHistory, upcastArgParserFun(parseCardinalDfsOrHistory))],
        conflictingOptions: [
            ["--wrap-around", "--boundaries-action"],
            ["--wrap-around", "--boundaries"],
        ],
    )

    public var rawBoundaries: Boundaries? = nil // todo cover boundaries wrapping with tests
    public var rawBoundariesAction: WhenBoundariesCrossed? = nil
    public var failIfFullscreen: Bool = false
    public var failIfMacosNativeFullscreen: Bool = false
    fileprivate var wrapAroundAlias: Bool = false
    public var dfsIndex: UInt32? = nil
    public var cardinalDfsOrHistory: CardinalDfsOrHistory? = nil
    public var floatingAsTiling: Bool = true

    public var cardinalOrDfsDirection: CardinalOrDfsDirection? {
        get {
            switch cardinalDfsOrHistory {
                case .cardinalOrDfs(let direction): direction
                case .history, nil: nil
            }
        }
        set {
            cardinalDfsOrHistory = newValue.map { .cardinalOrDfs($0) }
        }
    }

    public var historyNavigation: HistoryNavigation? {
        switch cardinalDfsOrHistory {
            case .history(let navigation): navigation
            case .cardinalOrDfs, nil: nil
        }
    }

    public init(rawArgs: StrArrSlice, cardinalOrDfsDirection: CardinalOrDfsDirection) {
        self.commonState = .init(rawArgs)
        self.cardinalOrDfsDirection = cardinalOrDfsDirection
    }

    public init(rawArgs: StrArrSlice, windowId: UInt32) {
        self.commonState = .init(rawArgs)
        self.windowId = windowId
    }

    public init(rawArgs: StrArrSlice, dfsIndex: UInt32) {
        self.commonState = .init(rawArgs)
        self.dfsIndex = dfsIndex
    }

    public init(rawArgs: StrArrSlice, historyNavigation: HistoryNavigation) {
        self.commonState = .init(rawArgs)
        self.cardinalDfsOrHistory = .history(historyNavigation)
    }

    public enum Boundaries: String, CaseIterable, Equatable, Sendable {
        case workspace
        case allMonitorsOuterFrame = "all-monitors-outer-frame"
    }
    public enum WhenBoundariesCrossed: String, CaseIterable, Equatable, Sendable {
        case stop = "stop"
        case fail = "fail"
        case wrapAroundTheWorkspace = "wrap-around-the-workspace"
        case wrapAroundAllMonitors = "wrap-around-all-monitors"
    }
}

public enum HistoryNavigation: String, CaseIterable, Equatable, Sendable {
    case back
    case forward
}

public enum CardinalDfsOrHistory: Equatable, Sendable {
    case cardinalOrDfs(CardinalOrDfsDirection)
    case history(HistoryNavigation)
}

extension CardinalDfsOrHistory: CaseIterable {
    public static var allCases: [CardinalDfsOrHistory] {
        CardinalOrDfsDirection.allCases.map { .cardinalOrDfs($0) } + HistoryNavigation.allCases.map { .history($0) }
    }
}

extension CardinalDfsOrHistory: RawRepresentable {
    public typealias RawValue = String

    public init?(rawValue: String) {
        if let direction = CardinalOrDfsDirection(rawValue: rawValue) {
            self = .cardinalOrDfs(direction)
        } else if let navigation = HistoryNavigation(rawValue: rawValue) {
            self = .history(navigation)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
            case .cardinalOrDfs(let direction): direction.rawValue
            case .history(let navigation): navigation.rawValue
        }
    }
}

public enum FocusCmdTarget {
    case direction(CardinalDirection)
    case windowId(UInt32)
    case dfsIndex(UInt32)
    case dfsRelative(DfsNextPrev)
    case historyBack
    case historyForward

    var isDfsRelative: Bool {
        switch self {
            case .dfsRelative: true
            default: false
        }
    }

    var isHistory: Bool {
        switch self {
            case .historyBack, .historyForward: true
            default: false
        }
    }
}

extension FocusCmdArgs {
    public var target: FocusCmdTarget {
        if let historyNavigation {
            return switch historyNavigation {
                case .back: .historyBack
                case .forward: .historyForward
            }
        }
        if let cardinalOrDfsDirection {
            return switch cardinalOrDfsDirection {
                case .direction(let dir): .direction(dir)
                case .dfsRelative(let nextPrev): .dfsRelative(nextPrev)
            }
        }
        if let windowId {
            return .windowId(windowId)
        }
        if let dfsIndex {
            return .dfsIndex(dfsIndex)
        }
        die("Parser invariants are broken")
    }

    public var boundaries: Boundaries { rawBoundaries ?? .workspace }
    public var boundariesAction: WhenBoundariesCrossed {
        wrapAroundAlias ? .wrapAroundTheWorkspace : (rawBoundariesAction ?? .stop)
    }
}

func parseFocusCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusCmdArgs> {
    return parseSpecificCmdArgs(FocusCmdArgs(rawArgs: args), args)
        .flatMap { (raw: FocusCmdArgs) -> ParsedCmd<FocusCmdArgs> in
            raw.boundaries == .workspace && raw.boundariesAction == .wrapAroundAllMonitors
                ? .failure("\(raw.boundaries.rawValue) and \(raw.boundariesAction.rawValue) is an invalid combination of values")
                : .cmd(raw)
        }
        .filter("Mandatory argument is missing. \(CardinalDfsOrHistory.unionLiteral), --window-id or --dfs-index is required") {
            $0.cardinalDfsOrHistory != nil || $0.windowId != nil || $0.dfsIndex != nil
        }
        .filter("--window-id is incompatible with other options") {
            $0.windowId == nil || $0 == FocusCmdArgs(rawArgs: args, windowId: $0.windowId.orDie())
        }
        .filter("--dfs-index is incompatible with other options") {
            $0.dfsIndex == nil || $0 == FocusCmdArgs(rawArgs: args, dfsIndex: $0.dfsIndex.orDie())
        }
        .filter("--fail-if-fullscreen/--fail-if-macos-native-fullscreen require using (left|down|up|right) argument") {
            if !$0.failIfFullscreen && !$0.failIfMacosNativeFullscreen {
                return true
            }
            return switch $0.target {
                case .direction: true
                case .dfsIndex, .dfsRelative, .windowId, .historyBack, .historyForward: false
            }
        }
        .filter("(dfs-next|dfs-prev) only supports --boundaries workspace") {
            $0.target.isDfsRelative.implies($0.boundaries == .workspace)
        }
        .filter("(back|forward) is incompatible with other options") {
            !$0.target.isHistory || (
                $0.rawBoundaries == nil &&
                    $0.rawBoundariesAction == nil &&
                    !$0.wrapAroundAlias &&
                    $0.floatingAsTiling &&
                    !$0.failIfFullscreen &&
                    !$0.failIfMacosNativeFullscreen
            )
        }
}

private func parseCardinalDfsOrHistory(i: PosArgParserInput) -> ParsedCliArgs<CardinalDfsOrHistory> {
    .init(parseEnum(i.arg, CardinalDfsOrHistory.self), advanceBy: 1)
}

private func parseBoundariesAction(i: SubArgParserInput) -> ParsedCliArgs<FocusCmdArgs.WhenBoundariesCrossed> {
    if let arg = i.nonFlagArgOrNil() {
        return .init(parseEnum(arg, FocusCmdArgs.WhenBoundariesCrossed.self), advanceBy: 1)
    } else {
        return .fail("<action> is mandatory", advanceBy: 0)
    }
}

private func parseBoundaries(i: SubArgParserInput) -> ParsedCliArgs<FocusCmdArgs.Boundaries> {
    if let arg = i.nonFlagArgOrNil() {
        return .init(parseEnum(arg, FocusCmdArgs.Boundaries.self), advanceBy: 1)
    } else {
        return .fail("<boundary> is mandatory", advanceBy: 0)
    }
}
