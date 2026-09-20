import SpikeProbes
let args = Set(CommandLine.arguments.dropFirst())
let all = args.isEmpty || args.contains("all")
if all || args.contains("cursor") { print(cursorProbe().text) }
if all || args.contains("crypto") { print(cryptoProbe().text) }
if all || args.contains("clocks") { print(clockProbe().text) }
if all || args.contains("timers") { print(timerProbe(quick: args.contains("quick")).text) }
if all || args.contains("sockets") { print(socketProbe(quick: args.contains("quick")).text) }
if all || args.contains("throughput") { print(throughputProbe(quick: args.contains("quick")).text) }
if all || args.contains("video") { print(videoProbe().text) }
if all || args.contains("path") { print(pathProbe().text) }
if args.contains("codec") { print(codecLatencyProbe().text) }  // not in "all": ~1 min
if args.contains("codecapi") { print(codecAPIProbe().text) }
