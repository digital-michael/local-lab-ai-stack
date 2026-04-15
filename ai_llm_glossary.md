# AI & LLM Glossary (Layered + Reasoning + Model Capabilities)

Generated: 2026-04-09

---

## Table of Contents

- [Glossary of Terms](#glossary-of-terms)
  - [Consumer-Level Concepts](#consumer-level-concepts)
    - [Artificial Intelligence (AI)](#artificial-intelligence-ai)
    - [Generative AI](#generative-ai)
    - [Large Language Model (LLM)](#large-language-model-llm)
    - [Prompt](#prompt)
    - [Completion](#completion)
    - [Chatbot](#chatbot)
    - [Multimodal AI](#multimodal-ai)
    - [Hallucination](#hallucination)
  - [Application Layer](#application-layer)
    - [Use Case](#use-case)
    - [Workflow](#workflow)
    - [Agent](#agent)
    - [Tool Use](#tool-use)
    - [RAG](#rag)
    - [Context Window](#context-window)
  - [Model Behavior](#model-behavior)
    - [Temperature](#temperature)
    - [Token](#token)
    - [Latency](#latency)
  - [Training Paradigms](#training-paradigms)
    - [Pretraining](#pretraining)
    - [Fine-tuning](#fine-tuning)
    - [RLHF](#rlhf)
  - [Architecture](#architecture)
    - [Transformer](#transformer)
    - [Attention](#attention)
    - [Embedding](#embedding)
  - [Data Representation](#data-representation)
    - [Tokenization](#tokenization)
    - [Embedding Space](#embedding-space)
  - [Retrieval Systems](#retrieval-systems)
    - [Vector Database](#vector-database)
    - [Similarity Search](#similarity-search)
  - [Training Mechanics](#training-mechanics)
    - [Loss Function](#loss-function)
    - [Gradient Descent](#gradient-descent)
    - [Weights](#weights)
  - [Evaluation](#evaluation)
    - [Benchmark](#benchmark)
    - [Perplexity](#perplexity)
  - [Safety](#safety)
    - [Alignment](#alignment)
    - [Guardrails](#guardrails)
  - [Advanced](#advanced)
    - [MoE](#moe)
    - [Quantization](#quantization)
    - [Inference](#inference)
  - [Math Foundations](#math-foundations)
    - [Softmax](#softmax)
    - [Logits](#logits)
    - [Cross-Entropy](#cross-entropy)
- [Ways of Reasoning](#ways-of-reasoning)
  - [Zero-Shot](#zero-shot)
  - [Few-Shot](#few-shot)
  - [Chain of Thought (CoT)](#chain-of-thought-cot)
  - [Self-Consistency](#self-consistency)
  - [Tree of Thoughts](#tree-of-thoughts)
  - [ReAct (Reason + Act)](#react-reason--act)

---

## Glossary of Terms

## Consumer-Level Concepts

### Artificial Intelligence (AI)

| Key | Values |
|---|---|
| **Purpose** | Broad intelligent systems |
| **Training** | massive datasets |
| **Context** | N/A |
| **Tools** | optional |

### Generative AI

| Key | Values |
|---|---|
| **Purpose** | Creates content |
| **Training** | large multimodal corpora |
| **Context** | medium–large |
| **Tools** | often integrated |

### Large Language Model (LLM)

| Key | Values |
|---|---|
| **Purpose** | Text-focused generative model |
| **Training** | self-supervised text corpora |
| **Context** | 8K–1M+ tokens |
| **Tools** | APIs, plugins |

### Prompt

| Key | Values |
|---|---|
| **Purpose** | Input instruction |
| **Training** | none |
| **Context** | consumes tokens |
| **Tools** | may trigger |

### Completion

| Key | Values |
|---|---|
| **Purpose** | Model output |
| **Training** | learned generation |
| **Context** | bounded by window |
| **Tools** | may include tool calls |

### Chatbot

| Key | Values |
|---|---|
| **Purpose** | Conversational interface |
| **Training** | dialogue tuning |
| **Context** | session-based |
| **Tools** | often integrated |

### Multimodal AI

| Key | Values |
|---|---|
| **Purpose** | Handles text, image, audio |
| **Training** | multimodal datasets |
| **Context** | large |
| **Tools** | strong integration |

### Hallucination

| Key | Values |
|---|---|
| **Purpose** | Incorrect confident output |
| **Training** | mitigation via RLHF |
| **Context** | worsens with gaps |
| **Tools** | reduced via RAG |

---

## Application Layer

### Use Case
- Task-specific application
- Training: sometimes fine-tuned
- Context: task dependent
- Tools: often required

### Workflow
- Multi-step system
- Training: modular
- Context: distributed
- Tools: essential

### Agent
- Autonomous AI system
- Training: instruction + RLHF
- Context: extended via memory
- Tools: critical

### Tool Use
- External function calling
- Training: structured outputs
- Context: small
- Tools: core feature

### RAG
- Retrieval before generation
- Training: embeddings + LLM
- Context: extended externally
- Tools: vector DB

### Context Window
- Max tokens handled
- Training: architecture-limited
- Context: defines capability
- Tools: indirectly affected

---

## Model Behavior

### Temperature
- Randomness control
- Training: none
- Context: N/A
- Tools: none

### Token
- Text unit
- Training: tokenizer
- Context: core constraint
- Tools: none

### Latency
- Response time
- Training: infra-dependent
- Context: larger = slower
- Tools: affects pipelines

---

## Training Paradigms

### Pretraining
- Base learning phase
- Training: massive compute
- Context: general
- Tools: none

### Fine-tuning
- Specialization
- Training: smaller dataset
- Context: similar to base
- Tools: improves integration

### RLHF
- Human feedback tuning
- Training: expensive
- Context: unchanged
- Tools: improves safety

---

## Architecture

### Transformer
- Core architecture
- Training: compute-heavy
- Context: scalable
- Tools: indirect

### Attention
- Focus mechanism
- Training: learned weights
- Context: scales quadratically
- Tools: none

### Embedding
- Vector representation
- Training: learned mapping
- Context: reusable
- Tools: critical for RAG

---

## Data Representation

### Tokenization
- Text splitting
- Training: predefined
- Context: affects efficiency
- Tools: none

### Embedding Space
- Semantic vector space
- Training: learned
- Context: externalizable
- Tools: vector DB

---

## Retrieval Systems

### Vector Database
- Stores embeddings
- Training: none
- Context: external memory
- Tools: core for RAG

### Similarity Search
- Finds related vectors
- Training: none
- Context: extends knowledge
- Tools: essential

---

## Training Mechanics

### Loss Function
- Error measurement
- Training: central
- Context: none
- Tools: none

### Gradient Descent
- Optimization
- Training: iterative
- Context: none
- Tools: none

### Weights
- Model parameters
- Training: learned
- Context: fixed at inference
- Tools: none

---

## Evaluation

### Benchmark
- Performance test
- Training: none
- Context: varies
- Tools: none

### Perplexity
- Prediction quality
- Training: evaluation metric
- Context: none
- Tools: none

---

## Safety

### Alignment
- Human value matching
- Training: RLHF
- Context: unchanged
- Tools: policy layers

### Guardrails
- Output constraints
- Training: rule-based + learned
- Context: applied runtime
- Tools: filters

---

## Advanced

### MoE
- Selective activation
- Training: complex
- Context: efficient scaling
- Tools: none

### Quantization
- Lower precision
- Training: post-process
- Context: unchanged
- Tools: improves deployment

### Inference
- Running model
- Training: none
- Context: active
- Tools: integrates

---

## Math Foundations

### Softmax
- Probability conversion
- Training: core
- Context: none
- Tools: none

### Logits
- Raw scores
- Training: intermediate
- Context: none
- Tools: none

### Cross-Entropy
- Loss metric
- Training: standard
- Context: none
- Tools: none

---

## Ways of Reasoning

### Zero-Shot

| Key|Values |
|---|---|
| **Description** | No examples provided |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4<br>2. Claude 3<br>3. Gemini |

### Few-Shot

| Key|Values |
|---|---|
| **Description** | Prompt includes examples |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4<br>2. Claude 3<br>3. Llama 3 |

### Chain of Thought (CoT)

| Key|Values |
|---|---|
| **Description** | Step-by-step reasoning |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4<br>2. Claude 3<br>3. Gemini 1.5 |

### Self-Consistency

| Key|Values |
|---|---|
| **Description** | Multiple reasoning paths, choose best |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4<br>2. PaLM 2 |

### Tree of Thoughts

| Key|Values |
|---|---|
| **Description** | Branching reasoning exploration |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4 (research use) |

### ReAct (Reason + Act)

| Key|Values |
|---|---|
| **Description** | Combines reasoning with tool use |
| **When To Use** | |
| **When Not To Use** | |
| **Rating** | |
| **Models** | 1. GPT-4<br>2. Claude 3 |

---

