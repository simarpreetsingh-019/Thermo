## Mac load and heat (Thermo)

Before starting heavy work on this Mac (training, large builds, renders, video export, local LLMs), run:

```bash
thermo headroom --kind gpu --json      # or --kind cpu / memory, add --memory-gb N if known
```

Exit code 0 = go, 3 = wait, 4 = no. On wait, tell the user the `advice` line and offer
`thermo wait-cool --target 70`; never quit apps without asking. On no, don't start the job.
For "why is my Mac slow/hot": `thermo status --json`, then `thermo apps --json`.
