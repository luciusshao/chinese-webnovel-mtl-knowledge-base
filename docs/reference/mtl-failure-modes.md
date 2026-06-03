# Common MTL Failure Modes

## 1. Name Drift

One character gets multiple English names across chapters.

Fix:

- lock names in a glossary;
- repeat the glossary in every translation request.

## 2. Realm Drift

Cultivation stages get translated differently in different chapters.

Fix:

- define a realm ladder once;
- reject outputs that change the ladder.

## 3. Over-Westernization

Chinese fantasy concepts get flattened into generic Western fantasy wording.

Fix:

- preserve key terms like `qi`, `dao`, and `dantian` when appropriate;
- state this explicitly in the prompt.

## 4. Summary Instead Of Translation

The model drops details and produces a cleaner but incomplete chapter.

Fix:

- explicitly forbid summarization;
- ask for full content fidelity.

## 5. Tone Collapse

Serialized web novel voice becomes bland or overly formal.

Fix:

- ask for readable but not overly literary English;
- keep genre tone in the prompt.
