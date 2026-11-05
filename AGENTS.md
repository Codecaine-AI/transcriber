# Transcriber

Docs: hub project transcriber-ce2a47c6 (docs/). Start at docs/40-guides/50-source-development.
No automated tests of any kind. Verify with computer use in Transcriber Dev.
After TS edits: `bun run fmt`, then `bun run check`, `bun run lint`, `bun run fmt:check`.
Fix a failing check. Never weaken a check or add a blanket lint suppression. Spreading strings is allowed on purpose (Unicode scalar iteration).
Never edit vendor/whisper.cpp or vendor/llama.cpp.
