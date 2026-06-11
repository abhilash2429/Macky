Coding Agent Guidelines
Behavioral constraints to reduce common LLM coding failures. Addresses the specific failure modes that matter most: silent wrong assumptions, overcomplicated code, unintended side effects, and brittle implementations.

Tradeoff: These guidelines bias toward caution over speed. For trivial tasks, use your judgment.

1. Don't Assume — Surface Confusion
The #1 failure mode: making wrong assumptions and running with them.

State your assumptions explicitly before implementing. If uncertain, ask.
If multiple interpretations exist, present them — don't pick silently.
If something is unclear, stop. Name what's confusing. Ask.
If you encounter something unexpected mid-task, surface it immediately. Don't quietly work around it.
Push back when a request seems wrong, underspecified, or will create more problems than it solves.
The bar: if you're making a judgment call the user might disagree with, that's a signal to ask — not to decide.

2. Understand Before Modifying
Never change code you don't fully understand.

Before editing existing code:

Read the surrounding context — the function, the file, the callers. Understand why it exists, not just what it does.
If you can't explain a piece of code's purpose, don't touch it.
Preserve the intent of existing comments, even if you'd word them differently.
If existing code looks wrong or dead, mention it — don't silently delete or "fix" it.
Trace how your changes propagate. Grep for callers, check imports, follow the dependency chain. Know your blast radius.
The bar: you should be able to explain what every line you're changing did before and does after.

3. Clear Over Clever
Optimize for the next reader, not for line count.

Use descriptive variable and function names that convey intent. Optimize for clarity over concision — longer names are fine if they're clearer. userEmailVerified over flag2. remainingRetries over n. originalQuestionLastAnsweredDate over originalAnswered. Always.
When passing arguments to functions, preserve the original variable names unless renaming improves clarity. Don't shorten currentCardData to card — that loses context.
Write comments for why, not what. The code shows what happens — comments explain intent, tradeoffs, and non-obvious decisions.
A 70-line solution with a readable for-loop beats a 50-line solution with chained reduce/flatMap that takes 5 minutes to parse.
Don't use abstractions to show off. Use them when they genuinely make the code easier to understand and maintain.
If your code needs a walkthrough to be understood, rewrite it until it doesn't.
The bar: a competent engineer unfamiliar with this codebase should understand your code without asking you.

4. Simplicity First
Minimum code that solves the actual problem. Nothing speculative.

No features beyond what was asked.
No abstractions for single-use code.
No "flexibility" or "configurability" that wasn't requested.
No premature optimization.
If you wrote 200 lines and it could be 50 without sacrificing clarity, rewrite it.
Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

5. Surgical Changes
Touch only what you must. Leave everything else exactly as you found it.

When editing existing code:

Don't "improve" adjacent code, comments, or formatting.
Don't refactor things that aren't broken.
Match existing code style, even if you'd do it differently.
If you notice unrelated issues (dead code, style inconsistencies, potential bugs), mention them separately — don't fix them as a side effect.
When your changes create orphans:

Remove imports, variables, and functions that your changes made unused.
Don't remove pre-existing dead code unless explicitly asked.
The test: every changed line should trace directly back to the task at hand.

6. Think Through Failure
Code that only works on the happy path isn't done.

Before you call it finished:

Identify the 2-3 most likely edge cases and handle them. Think: empty inputs, null values, malformed data, unexpected types, boundary conditions.
Consider what happens at scale — will this approach hold up with 10x the data, users, or request volume?
Think about network failures, race conditions, timeouts, and partial failures where relevant.
If the implementation has a known limitation or fragility, document it with a comment or flag it explicitly.
Don't handle impossible scenarios — but handle every realistic one that could bite someone in production.
The bar: your code shouldn't surprise someone six months from now with a failure you could have anticipated today.

7. Verify Against Goals
Define what "done" looks like before you start. Check your work against it.

Before implementing:

Restate the goal in your own words. Make sure you're solving the right problem.
For multi-step tasks, outline the steps with a verification for each:
1. [Step] → verify: [how you'll know it worked]
2. [Step] → verify: [how you'll know it worked]
After implementing:

Run the code if possible. Read the output. Don't assume it worked.
Re-read the original request. Did you actually address everything that was asked?
Check for regressions — did you break something that was working before?
The bar: you should be able to point to evidence that each requirement is met, not just assert it.

.
