# HerAgent: Rethinking the Automated Environment Deployment via Hierarchical Test Pyramid

An LLM-driven agent that automatically reproduces software bugs by building a code knowledge graph, generating environment setup scripts, and executing test suites inside isolated Docker containers.

## Architecture

The system orchestrates three [LangGraph](https://github.com/langchain-ai/langgraph) subgraphs in sequence:

| Stage | Subgraph | Description |
|-------|----------|-------------|
| 1 | **Testsuite Extraction** | Parses CI/CD configs, pytest settings, and build files to extract multi-level test commands |
| 2 | **Environment Implementation** | Queries the code knowledge graph (Neo4j) for context and generates a `prometheus_setup.sh` script |
| 3 | **Environment Repair** | Iteratively executes, analyzes errors, and patches the setup until the environment is functional |

A **code knowledge graph** (AST + text chunks, stored in Neo4j) provides semantic codebase understanding throughout the pipeline.

## Prerequisites

| Dependency | Version |
|------------|---------|
| Python | >= 3.11 |
| Neo4j | 5.x |
| Docker | latest |
| Git | latest |

## Quick Start

### 1. Install dependencies

```bash
# Option A: pinned versions (recommended)
pip install -r requirements.txt

# Option B: via pyproject.toml
pip install .
```

### 2. Configure environment

```bash
cp example.env .env
mkdir -p working_dir
```

Edit `.env` with your settings:

```dotenv
PROMETHEUS_NEO4J_URI=bolt://localhost:7687
PROMETHEUS_NEO4J_USERNAME=neo4j
PROMETHEUS_NEO4J_PASSWORD=password
PROMETHEUS_WORKING_DIRECTORY=working_dir/
PROMETHEUS_ADVANCED_MODEL=gpt-4o
PROMETHEUS_BASE_MODEL=gpt-4o
PROMETHEUS_OPENAI_FORMAT_API_KEY=sk-xxx
```

Multi-provider LLM support: OpenAI, Anthropic, Gemini, and Vertex AI. Set the corresponding `PROMETHEUS_*_API_KEY` as needed.

### 3. Start Neo4j

```bash
docker run -d --name neo4j_prometheus \
  -p 7474:7474 -p 7687:7687 \
  -e NEO4J_AUTH=neo4j/password \
  -e NEO4J_PLUGINS='["apoc"]' \
  -e NEO4J_dbms_memory_heap_max__size=4G \
  -e NEO4J_dbms_memory_pagecache_size=2G \
  neo4j:5
```

### 4. Run

```bash
python3 -m app.main \
  --dataset_file_path projects/executionAgent.txt \
  --github_token "$GITHUB_TOKEN" \
  -w 4 \
  --docker_image_name envagent-multi-language:v1.1
```

## CLI Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--dataset_file_path` | `-d` | Path to the project list file (required) | — |
| `--github_token` | `-g` | GitHub token for private repos | `None` |
| `--max_workers` | `-w` | Parallel processing threads | `4` |
| `--dockerfile_template` | `-t` | Custom Dockerfile template path | `None` |
| `--docker_image_name` | `-i` | Base Docker image name | `None` |

### Dataset file format

One project per line: `<owner/repo> <git_tag> [project_path] [docker_image_name]`

```text
pallets/flask v3.0.0
django/django 5.0 django
```

Lines starting with `#` are ignored.

### Available Benchmarks

| Benchmark | Dataset File |
|-----------|-------------|
| EnvBench-Python | `projects/envbench-python.txt` |
| ExecutionAgent | `projects/executionAgent.txt` |
| Installamatic | `projects/installamatic_dataset.txt` |
| Piper-EnvBench | `projects/piper-envbench-test.txt` |
| Repo2Run | `projects/repo2run.txt` |

Example — run on the ExecutionAgent benchmark with 4 workers:

```bash
python3 -m app.main \
  --dataset_file_path projects/executionAgent.txt \
  --github_token "$GITHUB_TOKEN" \
  -w 4 \
  --docker_image_name envagent-multi-language:v1.1
```

## Project Structure

```
app/
├── main.py                  # CLI entry point & parallel orchestrator
├── configuration/           # Dynaconf-based settings loader
├── container/               # Docker container lifecycle management
├── lang_graph/
│   ├── subgraphs/           # LangGraph workflow definitions
│   │   ├── testsuite_subgraph.py
│   │   ├── env_implement_subgraph.py
│   │   └── env_repair_subgraph.py
│   ├── testsuite_nodes/     # Test command extraction nodes
│   ├── env_nodes/           # Environment setup generation nodes
│   ├── repair_nodes/        # Iterative repair loop nodes
│   └── states/              # LangGraph state schemas
├── services/
│   ├── knowledge_graph_service.py   # KG build & retrieval
│   ├── llm_service.py               # Multi-provider LLM abstraction
│   ├── neo4j_service.py             # Neo4j connection management
│   └── repository_service.py        # Git clone, cache & versioning
├── graph/                   # Knowledge graph data structures
├── parser/                  # Tree-sitter AST parsing
├── neo4j_manage/            # Neo4j CRUD operations
└── utils/                   # Logging, helpers
```

## Output Artifacts

After execution, each project container generates:

| File | Description |
|------|-------------|
| `prometheus_setup.sh` | Auto-generated environment setup script |
| `prometheus_testsuite_commands.json` | Extracted multi-level test commands |
| `prometheus_testsuite_states_*.json` | Intermediate testsuite extraction states |

Results are aggregated into `<working_dir>/projects/<timestamp>/project_results.json`.

### Inspecting a container

```bash
# Enter the container (ID printed in logs)
docker exec -it <container_id> /bin/bash

# Run the generated setup script
bash /app/prometheus_setup.sh
```

Host files are volume-mapped to `/app` inside the container for real-time sync.

## Notes

- Ensure Docker daemon is running and the current user has Docker permissions.
- Building knowledge graphs for large repositories is memory-intensive; tune Neo4j heap/pagecache accordingly.
- Postgres is optional — only needed if LangGraph checkpoint persistence is enabled.
