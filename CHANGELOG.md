# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0-rc1] - 2024-XX-XX

### Added

#### Recursive Language Models (RLM)
- **`Synaptic.RLM.process/3`** - Main entry point for processing large contexts that exceed model context windows
- **RLM Architecture**:
  - `Synaptic.RLM.Environment` - Manages external context, variables, and answer state
  - `Synaptic.RLM.Budget` - Tracks token usage, costs, and iteration counts with separate root/sub call counters
  - `Synaptic.RLM.Tools` - Built-in tools for RLM operations
- **Built-in RLM Tools**:
  - `slice_context` - Extract specific character ranges from context
  - `search_context` - Regex search with position tracking
  - `llm_query` - Query sub-agent with content and question
  - `llm_batch` - Parallel batch processing via sub-agent
  - `set_variable` / `get_variable` - Store and retrieve intermediate state
  - `set_answer` - Mark final answer and signal completion
  - `context_info` - Get context metadata (length, line count, previews)
- **RLM Features**:
  - Budget tracking across root and sub-agent calls
  - Sub-call enforcement to ensure root agents delegate work (`min_subcalls_per_root`, `max_enforcement_attempts`)
  - Progress logging via optional callback
  - Configurable system prompts
  - Custom tools and dynamic tool builders
  - Accept content as answer option for flexible completion detection
- **Dev Tools**:
  - `Synaptic.Dev.RLMDemoWorkflow` - Demo workflow showcasing RLM functionality
  - `Synaptic.Dev.RLMModuleRegistry` - Module tracking to avoid duplication in generated content

#### Thread Support
- **OpenAI Responses API Integration** - Automatic adapter selection when `thread: true` or `previous_response_id:` is provided
- Backward compatible with existing Chat Completions API usage
- Support for threaded conversations with response ID tracking

#### Enhanced Usage Tracking
- **Aggregated Token Usage** - `return_usage: true` now aggregates tokens across entire tool-call loops:
  - Initial request tokens
  - Tool call response tokens
  - Final assistant response tokens after tool execution
- Usage tracking works seamlessly with multiple tool-call cycles

#### Request Timeouts
- Configurable `receive_timeout` option for OpenAI adapter
- Per-call timeout support: `Synaptic.Tools.chat(messages, receive_timeout: 180_000)`
- Global configuration via `Synaptic.Tools.OpenAI` config
- Default timeout of 120 seconds (120,000 ms)
- Timeout support for both regular and streaming requests

### Changed
- Version bumped to `0.3.0-rc1` (release candidate)
- Improved error handling and logging in RLM processing
- Enhanced budget tracking to separate root and sub-agent call counts
- Updated `publish.sh` to handle version formats including release candidates (e.g., `0.3.0-rc1`)

### Fixed
- Usage aggregation now correctly tracks tokens across multiple tool-call cycles
- Fixed timeout handling in streaming requests

## [0.2.6] - Previous Release

### Features
- Workflow DSL with `use Synaptic.Workflow`, `step/3`, `commit/0`
- In-memory runtime with supervised `Synaptic.Runner` processes
- Suspension + resume API for human involvement
- LLM abstraction with OpenAI adapter (extensible)
- Tool calling support with handler functions
- Streaming responses with real-time PubSub events
- Step-level scorers for quality evaluation
- Parallel and async steps
- Telemetry instrumentation for steps, LLM calls, and side effects
- YAML-based workflow testing framework
- Dev demo workflow (`Synaptic.Dev.DemoWorkflow`)
- Named agents for reusable model configurations
- Structured JSON responses
- Starting workflows at specific steps
- Stopping workflows from within steps or externally

---

[Unreleased]: https://github.com/bionaut/synaptic/compare/v0.3.0-rc1...HEAD
[0.3.0-rc1]: https://github.com/bionaut/synaptic/compare/v0.2.6...v0.3.0-rc1
[0.2.6]: https://github.com/bionaut/synaptic/releases/tag/v0.2.6
