# Strict Consistency Prompt

Use this when the model tends to drift on names, realms, and technical vocabulary.

```text
Translate this Chinese web novel chapter into English.

Strict rules:
1. Use the glossary exactly as written.
2. Do not invent alternate translations for any glossary term.
3. Do not summarize, condense, or skip lines.
4. Preserve chapter structure and dialogue order.
5. Keep cultivation and fantasy terminology internally consistent.
6. If a term is unclear, prefer a conservative literal rendering over inventing new lore.

Glossary:
[paste glossary here]

Chapter text:
[paste chapter here]
```

## When To Use It

- long novels with severe terminology drift;
- projects where glossary fidelity matters more than prose smoothness;
- revisions where earlier chapter terminology is already locked.
