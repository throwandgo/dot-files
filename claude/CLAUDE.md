## IDE
Always use Vim as the text editor or IDE. Open with `v <directory or file>`.

## Skills
Don't invoke a skill for a change you can already make correctly — propose the edit
directly. Reach for a skill when you need its specifics, not to validate a decision
you've already reached. Skill bodies can be very large (`update-config` is ~40k
tokens), so an unnecessary invocation is one of the most expensive things you can do.

## Tool output
Extract the lines you need rather than dumping surrounding context. When grepping
generated or minified files, print the match, not a wide window around it.

## Delegation
Dispatch to subagents by default for exploration, search, and verification — their
intermediate tool output stays out of the main conversation and only the conclusion
returns. Choose the model by task complexity, not by habit:
- haiku: mechanical, single-answer work (file lookups, status checks, commits)
- sonnet: ordinary implementation and multi-file search
- opus: judgment — design, review, ambiguous debugging
Work inline when the task depends on conversation context a subagent would lack.

## Context handoff
Prefer an explicit handoff over auto-compaction. When the conversation has grown
long, or when I say "handoff", stop and write a plan covering: what's done, what's
left, the key files, and decisions already made. Then propose exiting plan mode with
"clear context" so the plan carries forward as the new starting point.
Trigger it at ~30% of the current model's context window remaining. Compute that
percentage from the window of the model actually in use — never a fixed token count,
since windows differ per model. Auto-compaction fires near 20% remaining, so 30%
leaves room to write the plan first.

## Response style
Lead with the conclusion — the first sentence answers "what happened" or "what do I
do now". Supporting detail comes after, for when I want it.
Shorten by including less, not by compressing: drop anything that wouldn't change my
next action, and keep complete sentences. No filler, pleasantries, hedging, or
restating my question back to me. Don't narrate routine tool calls.
Never use invented abbreviations or arrow chains to save space — they cost the same
under the tokenizer and read worse. Tables only for genuinely tabular facts.
Answer what I asked; don't append a survey of options I didn't ask for.

## Verifying before recommending
Don't recommend, rank, or claim something is done when checking the premise is one
tool call away — measure first, then say it. Guard verification scripts against
silently passing on empty variables or absent files.
