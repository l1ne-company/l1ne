# Claude Code Guidelines

## NO GAMBIARRA POLICY - ASK FOR FEEDBACK INSTEAD

Due to the difficulty of implementing this codebase, we must strive to keep the code high quality, clean (not clean code), simple, modular, functional and super fast - More like a professional rust codebase (see dtolnay crates, or lib.rs/tracing for reference as to what this looks like). Gambiarras, hacks and duct taping must be COMPLETELY AVOIDED, in favor of robust, simple and general solutions.

In some cases, you will be asked to perform a seemingly impossible task, either because it is (and the user is unaware), or because you don't grasp how to do it correctly. In these cases, DO NOT ATTEMPT TO IMPLEMENT A HALF-BAKED SOLUTION JUST TO SATISFY THE USER'S REQUEST. If the task seems too hard, be honest that you could not solve it in the proper way, leave the code unchanged, explain the situation to the user and ask for further feedback and clarifications.

The user is a domain expert and will be able to not only assist, but to also suggest and think about the proper solutions in these cases.
