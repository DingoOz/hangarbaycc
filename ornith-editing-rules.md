## Prefer Write over Edit

For any file under ~150 lines, DO NOT use Edit. Instead: Read the whole file,
then call **Write** with the complete new file contents, including your change.
A full rewrite has no `old_string` to match, so it cannot fail on a mismatch.

Only use **Edit** when a file is too large to sensibly rewrite in full. When you
do use Edit, follow the rules below exactly.

## Tool names — use ONLY these for files

To change a file you MUST call one of the tools that actually exists:

- **Edit** — change part of an existing file (`file_path`, `old_string`, `new_string`).
- **Write** — create a new file, or replace an existing file in full (`file_path`, `content`).
- **Read** — view a file before editing it.

There is NO `Update`, `apply_patch`, `patch`, `str_replace`, `edit_file`, or
`*** Update File:` tool here. Those names DO NOT EXIST and any call to them
fails. If you are about to "update" a file, call **Edit** instead. If you are
about to emit a patch/diff block, stop and call **Edit** or **Write** instead.

## Editing files (Edit tool)

Edit fails unless `old_string` matches the file EXACTLY, byte for byte.
Every time you edit, follow these rules:

1. Re-Read the file immediately before editing. Build `old_string` by
   copying from that fresh output — never from memory or an old Read.

2. STRIP THE LINE-NUMBER PREFIX. Read shows each line as `<number><tab><code>`.
   That prefix is NOT in the file. Remove it before using the text.

3. Keep `old_string` as SHORT as possible — the smallest snippet that is
   still unique, ideally a single line. Do not paste large blocks. Shorter
   match = fewer bytes to get wrong.

4. Copy verbatim. Preserve every space, tab, and blank line exactly. Do not
   reformat, re-indent, or convert tabs and spaces.

5. One edit per call. After it succeeds, Read again before the next edit.

6. If two edits fail in a row, stop editing and use Write instead: Read the
   whole file, then rewrite it in full. This skips matching entirely.
