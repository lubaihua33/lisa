# AI Log Analyzer Prompts

This folder contains only the **actively used** system prompts and instruction files for the AI Log Analyzer multi-agent system.

## Active Prompt Files (Used in Code)

### Agent System Prompts
- **`log_search_system_prompt.txt`** - Instructions for the LogSearchAgent that handles searching and analyzing log files for error patterns
- **`code_search_system_prompt.txt`** - Instructions for the CodeSearchAgent that examines source code files and analyzes implementations

### Group Chat Orchestration
- **`log_analyzer_selection_system_prompt.txt`** - LLM-based selection strategy prompt for determining which agent should respond next in group chat
- **`log_analyzer_termination_system_prompt.txt`** - LLM-based termination strategy prompt for deciding when the analysis is complete
- **`group_chat_instructions.txt`** - Overall coordination instructions for the multi-agent group chat system

## Legacy/Reference Files (Located in Parent Directory)

The following files have been moved back to the main `ai_log_analyzer/` directory as they are not actively used in the current system:

- `system_prompt.txt` - Original system prompt
- `system_prompt_20250624.txt` - Dated version of system prompt  
- `system_prompt_copy.txt` - Backup copy of system prompt
- `system_prompt_copy2.txt` - Another backup copy
- `user_prompt.txt` - Sample user prompt
- `log_search_user_prompt.txt` - Sample user prompt for log search
- `code_search_user_prompt.txt` - Sample user prompt for code search
- `summarization_instructions.txt` - Instructions for log summarization

## File Organization Benefits

1. **Clean Separation** - Only actively used prompts are in this dedicated folder
2. **Easy Maintenance** - Developers can quickly find the prompts that matter for the running system
3. **Version Control** - Prompt changes can be tracked separately from code changes
4. **Modularity** - Each agent and strategy has its own dedicated prompt file
5. **No Clutter** - Legacy files don't interfere with active development
