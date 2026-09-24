# Tools

Code that supports the protocol definition in [`docs/`](../docs). Nothing here is needed to
implement the protocol; it exists so that every wire example in the specification can be
regenerated, and so that every default the specification chooses can be traced to a
measurement or a simulation.

| Directory | What it is | Status |
|---|---|---|
| [`vectors/`](vectors) | Generates every hex example in `docs/` and checks the documents against it | Planned (phase 2) |
| [`sim/`](sim) | Loss-recovery and rate-control simulator, and the resume latency budget | Recovery model done; rate control planned |
| [`probes/apple/mac/`](probes/apple/mac) | VideoToolbox costs on the resume path, measured on a Mac | Done; extensions planned |
| [`probes/apple/ios/`](probes/apple/ios) | iPad lifecycle, socket, decoder and network measurements | Planned (phase 1) |
| [`probes/apple/verify/`](probes/apple/verify) | Decodes recovery bitstreams from other encoders with VideoToolbox | Planned (phase 1) |
| [`probes/windows/`](probes/windows) | NVENC and QSV reference-recovery bitstreams | Planned (phase 1) |
| [`probes/results/`](probes/results) | Raw probe output, one file per device and run | Growing |

## Running what exists

The resume probe, on an Apple-silicon Mac:

```bash
swiftc -O -parse-as-library tools/probes/apple/mac/ResumeProbe.swift -o /tmp/resumeprobe
```

```bash
/tmp/resumeprobe 5
```

The first argument is the idle time in seconds before the warm-encoder measurements. A
second argument, `1080p`, `1440p` or `2160p`, limits the run to one resolution.

The recovery simulator:

```bash
swiftc -O -parse-as-library tools/sim/RecoverySim.swift -o /tmp/recoverysim
```

```bash
/tmp/recoverysim 30
```

The argument is simulated minutes per cell. The model and its assumptions are described at
the top of [`RecoverySim.swift`](sim/RecoverySim.swift).

The resume latency budget:

```bash
python3 tools/sim/resume_budget.py
```
