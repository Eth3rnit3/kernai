# 📦 Cahier des charges FINAL — Gem Ruby "Kernai"

---

# 🎯 Objectif

Créer une gem Ruby permettant de construire des agents IA via un **kernel minimaliste, extensible et dynamique**, basé sur :

* un **protocole universel de blocks structurés**
* un système de **skills dynamiques**
* une **boucle d’exécution contrôlée**
* une **compatibilité native avec les APIs conversationnelles LLM**
* un **streaming maîtrisé**
* une **observabilité complète**
* un **hot reload des skills et instructions**
* une **architecture sans dépendance externe**

---

# 🧠 Philosophie

* simplicité > magie
* protocole > abstraction
* backend > LLM
* dynamique > statique
* conversation pure > rôles spéciaux
* zéro dépendance

---

# 🧱 Architecture globale

```text
User / System Input
        ↓
     Kernel
        ↓
Messages → Provider → LLM
        ↓
Streaming / Response
        ↓
Block Parser (state machine)
        ↓
Dispatcher (par type)
        ↓
Skill / Output / Loop
```

---

# 🧩 Modèle conversationnel (CRITIQUE)

## 🔹 Rôles utilisés

| Rôle      | Utilisation                               |
| --------- | ----------------------------------------- |
| system    | instructions (unique, remplaçable)        |
| user      | input utilisateur + communication interne |
| assistant | réponses LLM                              |

---

## 🔹 Règles fondamentales

* Un seul message `system` actif
* Toujours en première position
* Remplacé lors d’un hot reload
* Aucune accumulation

---

## 🔹 Communication interne

Le système communique avec le LLM via des messages `user` contenant des blocks.

---

### Exemple : résultat de skill

```xml
<block type="result" name="postgres">
[
  { "id": 1, "name": "Alice" }
]
</block>
```

---

### Exemple : erreur

```xml
<block type="error" name="postgres">
Permission denied
</block>
```

---

# 🧠 Instructions système (OBLIGATOIRES)

Chaque agent DOIT inclure des conventions :

```text
Tu dois utiliser des blocks XML de la forme :

<block type="TYPE">
...
</block>

Types disponibles :
- command → exécuter une action
- json → données structurées
- final → réponse finale
- plan → raisonnement (optionnel)
- result → résultat d’une action
- error → erreur système

Quand tu veux exécuter une action :
→ utilise <block type="command">

Tu peux recevoir des blocks dans les messages user :
→ ils contiennent des résultats ou erreurs

Tu dois les interpréter correctement avant de continuer.
```

---

# 🔹 Agent

```ruby
agent = Kernai::Agent.new(
  instructions: -> { PromptStore.current },
  provider: MyProvider.new,
  model: "gpt-4.1",
  max_steps: 10
)
```

---

## 🔥 Instructions dynamiques (HOT RELOAD)

```ruby
agent.update_instructions("...")
```

ou

```ruby
agent.instructions = -> { fetch_prompt() }
```

👉 évalué à chaque step

---

# 🔌 Provider (LLM abstraction)

## Interface

```ruby
provider.call(messages:, model:, &block)
```

---

## Résolution

Ordre :

1. override Kernel.run
2. agent.provider
3. default_provider
4. erreur

---

## Contraintes

* aucun coupling API
* gère mapping messages → provider
* support streaming

---

# 🧩 Block System (central)

## Format

```xml
<block type="TYPE">
...
</block>
```

---

## Types MVP

* command
* json
* final
* plan
* result
* error

---

## DSL

```ruby
Kernai::Block.define :command do
  handle do |content, context|
    ...
  end
end
```

---

# 🧩 Skills

## Définition

```ruby
Kernai::Skill.define :postgres do
  input :query, String

  execute do |input|
    DB.execute(input[:query])
  end
end
```

---

## Registry

```ruby
Kernai::Skill.all
Kernai::Skill.find(:postgres)
```

---

# 🔥 Skills dynamiques (HOT RELOAD)

## API

```ruby
Kernai::Skill.reload!
Kernai::Skill.unregister(:postgres)
Kernai::Skill.load_from("app/skills/**/*.rb")
```

---

## Contraintes

* thread-safe
* mutable à runtime
* pas de restart

---

# ⚙️ Kernel

## Entrée

```ruby
Kernai::Kernel.run(agent, input, provider: optional)
```

---

## Loop

```ruby
loop do
  update_system_message

  provider.call(messages) do |chunk|
    stream_parser.push(chunk)

    stream_parser.each_event do |event|
      handle(event)
    end
  end

  break if max_steps || final reached
end
```

---

## Dispatch

* command → execute skill
* result/error → inject
* final → stop
* json → parse
* plan → log

---

# 🔁 Streaming

## Règles

| Type    | Streaming |
| ------- | --------- |
| final   | ✅         |
| json    | ⚠️ buffer |
| command | ❌         |

---

## Stream Parser

* state machine
* détecte blocks
* events :

  * chunk
  * block_start
  * block_complete

---

## API utilisateur

```ruby
Kernai::Kernel.run(agent, input) do |event|
  case event.type
  when :text_chunk
    print event.data
  end
end
```

---

# 📊 Observabilité

## Interface

```ruby
Kernai.logger.debug(...)
```

---

## Configuration

```ruby
config.logger = Logger.new(STDOUT)
config.debug = true
```

---

## Events

* llm.request
* llm.response
* stream.chunk
* block.detected
* block.complete
* skill.execute
* skill.result
* agent.complete

---

## Format

```ruby
Kernai.logger.debug(
  event: "skill.execute",
  skill: "postgres",
  step: 2
)
```

---

# 🔐 Sécurité

* max_steps obligatoire
* whitelist skills

```ruby
config.allowed_skills = [:postgres]
```

---

# 🧪 Tests

* parser blocks
* streaming parser
* hot reload skills
* hot reload instructions
* multi-provider
* loop kernel

---

# 🧱 Structure projet

```text
lib/
  kernai/
    agent.rb
    kernel.rb
    skill.rb
    block.rb
    parser.rb
    stream_parser.rb
    provider.rb
    message.rb
    logger.rb
    config.rb
```

---

# 🧠 Contraintes techniques

* Ruby ≥ 3.0
* 0 dépendance
* thread-safe
* lisible
* performant

---

# 🚀 Exemple complet

```ruby
agent = Kernai::Agent.new(
  instructions: -> { PromptStore.current },
  provider: OpenAIProvider.new,
  model: "gpt-4.1"
)

Kernai::Kernel.run(agent, "Liste les utilisateurs")
```

---

# 📌 Critères de validation

✅ protocole blocks fonctionnel
✅ conversation model respecté
✅ hot reload instructions OK
✅ hot reload skills OK
✅ multi-provider OK
✅ streaming OK
✅ observabilité complète
✅ aucune dépendance

---

# 💡 Résumé

Kernai est :

> un kernel d’agents IA basé sur un protocole universel de blocks, permettant une orchestration simple, dynamique, observable et totalement contrôlée sans dépendance externe.