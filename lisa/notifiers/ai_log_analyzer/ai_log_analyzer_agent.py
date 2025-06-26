import asyncio
import datetime
import logging
import re
import os
import aiohttp
import json
from bs4 import BeautifulSoup
from enum import Enum

from typing import List
from dataclasses import dataclass
from dotenv import load_dotenv
from semantic_kernel import Kernel
from semantic_kernel.utils.logging import setup_logging
from semantic_kernel.functions import kernel_function
from semantic_kernel.connectors.memory.in_memory import InMemoryVectorStore
from semantic_kernel.contents import ChatHistoryTruncationReducer
from semantic_kernel.connectors.ai.function_choice_behavior import FunctionChoiceBehavior
from semantic_kernel.contents.chat_history import ChatHistory, ChatMessageContent
from semantic_kernel.connectors.ai.open_ai import AzureOpenAISettings, AzureChatCompletion, OpenAITextEmbedding
from semantic_kernel.core_plugins import WebSearchEnginePlugin
from semantic_kernel.connectors.ai.open_ai.prompt_execution_settings.azure_chat_prompt_execution_settings import (
    AzureChatPromptExecutionSettings,
)


## Load environment variables from .env file
load_dotenv()


## Constants and Enums
class LogLevel(Enum):
    """LISA log levels"""
    CRITICAL = "CRITICAL"
    FATAL = "FATAL"
    ERROR = "ERROR"
    WARNING = "WARNING"
    WARN = "WARN"
    INFO = "INFO"
    DEBUG = "DEBUG"


class ErrorKeywords:
    """Keywords to identify error patterns in logs"""
    ERROR_PATTERNS = ['ERROR', 'EXCEPTION', 'FAILED', 'PANIC', 'TIMEOUT']
    CRITICAL_PATTERNS = ['CRITICAL', 'FATAL', 'PANIC']
    ALL_ERROR_PATTERNS = ERROR_PATTERNS + CRITICAL_PATTERNS


class CommandKeywords:
    """Keywords to identify command execution patterns"""
    EXECUTION_PATTERNS = ['executing', 'command', 'running', 'cmd']
    STATUS_PATTERNS = ['exit', 'return', 'status', 'failed', 'error']
    RESET_PATTERNS = ['exit', 'return']


class RegexPatterns:
    """Regex patterns for log parsing"""
    # LISA log format: timestamp[thread][level] component message
    LISA_LOG_PATTERN = r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\[(\d+)\]\[([^\]]+)\]\s+([^\s]+)\s+(.*)$'
    
    # Command patterns
    COMMAND_ID_PATTERN = r'\bcmd\[(\d+)\]'
    COMMAND_PATTERN = r"(executing|command|cmd|run).*?[:=]\s*(.+)"
    EXIT_CODE_PATTERN = r"(exit|return|status).*?[:=]\s*(\d+)"
    
    # File path patterns
    FILE_PATH_PATTERN = r'File "([^"]+)"'
    


class FileExtensions:
    """File extensions for log files"""
    LOG_EXTENSION = '.log'


class ExitCodes:
    """Exit code constants"""
    SUCCESS = '0'

class AnalysisLimits:
    """Configurable limits for analysis output"""
    MAX_ERROR_ENTRIES = 10
    MAX_RECENT_COMMANDS = 25

## Log entry structure
@dataclass
class LogEntry:
    """
    Structured representation of a LISA log entry.
    
    Represents a parsed log entry with all its components extracted
    from the LISA log format: timestamp[thread][level] component message
    """
    # Core log components
    timestamp: str = None
    thread_number: str = None
    log_level: str = None
    component: str = None
    cmd_id: str = None
    message: str = None
    
    # Metadata
    line_number: int = None
    raw_line: str = None
    
    # Classification flags
    is_error: bool = False
    is_critical: bool = False
    is_warning: bool = False
    
    def __post_init__(self):
        """Automatically classify the log entry based on log level."""
        if self.log_level:
            level_upper = self.log_level.upper()
            if LogLevel.CRITICAL.value in level_upper or LogLevel.FATAL.value in level_upper:
                self.is_critical = True
            elif LogLevel.ERROR.value in level_upper:
                self.is_error = True
            elif LogLevel.WARNING.value in level_upper or LogLevel.WARN.value in level_upper:
                self.is_warning = True
    
    def to_dict(self) -> dict:
        """Convert LogEntry to dictionary format for compatibility with existing code."""
        return {
            'timestamp': self.timestamp,
            'thread_number': self.thread_number,
            'log_level': self.log_level,
            'component': self.component,
            'cmd_id': self.cmd_id,
            'message': self.message,
            'line_number': self.line_number,
            'raw_line': self.raw_line,
            'is_error': self.is_error,
            'is_critical': self.is_critical,
            'is_warning': self.is_warning
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> 'LogEntry':
        """Create LogEntry from dictionary format."""
        return cls(
            timestamp=data.get('timestamp'),
            thread_number=data.get('thread_number'),
            log_level=data.get('log_level'),
            component=data.get('component'),
            cmd_id=data.get('cmd_id'),
            message=data.get('message'),
            line_number=data.get('line_number'),
            raw_line=data.get('raw_line'),
            is_error=data.get('is_error', False),
            is_critical=data.get('is_critical', False),
            is_warning=data.get('is_warning', False)
        )
    
    def __str__(self) -> str:
        """String representation showing key information."""
        if self.timestamp and self.thread_number and self.log_level:
            return f"[{self.timestamp}][{self.thread_number}][{self.log_level}] {self.component}: {self.message}"
        else:
            return self.raw_line or ""


## Helper functions
working_directory = os.path.dirname(os.path.realpath(__file__))

def load_test_data_by_index(index: int) -> dict:
    """
    Load test data from inputs.json file by index.
    
    Args:
        index: The index of the test case in the JSON array
        
    Returns:
        dict: Test data containing path, error_message, and outcome
        
    Raises:
        FileNotFoundError: If inputs.json file is not found
        IndexError: If index is out of range
        ValueError: If JSON format is invalid
    """
    json_path = os.path.join(working_directory, "test_logs", "log_analyzer_20250603", "inputs.json")
    
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            test_data = json.load(f)
        
        if not isinstance(test_data, list):
            raise ValueError("JSON file should contain an array of test cases")
        
        if index < 0 or index >= len(test_data):
            raise IndexError(f"Index {index} is out of range. Available indices: 0-{len(test_data)-1}")
        
        # print(f"test_data: {test_data[index]}")
        return test_data[index]
    
    except FileNotFoundError:
        raise FileNotFoundError(f"inputs.json file not found at {json_path}")
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON format in inputs.json: {e}")

def setup_debug_logging():
    debug_dir = os.path.join(working_directory,
        "resources",
        "tracing",
    )
    os.makedirs(debug_dir, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    tracing_filepath = os.path.join(debug_dir, f"debug_{timestamp}.log")
    setup_logging()
    logging.getLogger().setLevel(logging.DEBUG)

    # Create file handler and format each log message
    file_handler = logging.FileHandler(tracing_filepath)
    file_handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
    file_handler.setFormatter(formatter)

    # Remove any existing handlers except the file handler
    for handler in logging.getLogger().handlers[:]:
        logging.getLogger().removeHandler(handler)
    
    logging.getLogger().addHandler(file_handler)
    
    # # Enable detailed logging for Semantic Kernel components
    # logging.getLogger("semantic_kernel").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors.ai").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors.ai.open_ai").setLevel(logging.DEBUG)
    
    # # Enable HTTP request logging to capture all LLM requests
    # logging.getLogger("httpcore").setLevel(logging.DEBUG)
    # logging.getLogger("httpx").setLevel(logging.DEBUG)
    # logging.getLogger("openai").setLevel(logging.DEBUG)
    
    # print(f"Debug logging enabled. Log file: {tracing_filepath}")


def map_log_path_to_local(log_path: str, local_root: str, anchor_dir: str="lisa") -> str:
    """
    Maps a file path in the traceback to a local file system path based on the provided local root directory.
    log_path is expected to be relative to anchor_dir, which is typically the 'lisa' directory. 
    Skips the mapping if the log_path does not contain anchor_dir.
    """
    norm_log_path = os.path.normpath(log_path)
    norm_local_root = os.path.normpath(local_root)

    parts = norm_log_path.split(os.sep)
    if anchor_dir in parts:
        anchor_index = parts.index(anchor_dir)
        relative_path = os.path.join(*parts[anchor_index + 1:])
        # Join with local root
        local = os.path.join(norm_local_root, relative_path)
        return os.path.normpath(local)
    else:
        return ""
    
def parse_log_entry(log_entry: str, log_line: int) -> dict:
    """
    Parses a single log entry string into a structured LogEntry object.
    
    Args:
        log_entry: A single line from the log file.
        log_line: The line number of this entry in the log file.
        
    Returns:
        LogEntry object with parsed components: timestamp, thread number, log level, component, message.
        Returns None if the entry doesn't match the expected format.
    """
    if not log_entry or log_entry.strip() == "":
        return None
        
    log_pattern = RegexPatterns.LISA_LOG_PATTERN
    match = re.match(log_pattern, log_entry.strip())
    
    if match:
        structured = LogEntry(
            timestamp=match.group(1),
            thread_number=match.group(2),
            log_level=match.group(3), # Will automatically set classification flags if matches ERROR, CRTICAL, etc.
            component=match.group(4),
            message=match.group(5),
            line_number=log_line,
            raw_line=log_entry.strip()
        )

        cmd_id_match = re.search(RegexPatterns.COMMAND_ID_PATTERN, structured.component)
        if cmd_id_match:
            # Extract command ID from the message
            cmd_id = cmd_id_match.group(1).strip()
            structured.cmd_id = cmd_id

        print(f"Parsed log entry: {structured.to_dict()}")
        return structured.to_dict()
    
    # For error messages that don't match the standard format but contain ERROR/CRITICAL keywords
    error_keywords = ['ERROR', 'EXCEPTION', 'CRITICAL', 'FATAL', 'PANIC']
    for keyword in error_keywords:
        if keyword in log_entry.upper():
            # Try to extract parts in a best-effort way
            print(f"Found error keyword {keyword} in non-standard log: {log_entry}")
            return {
                'log_level': keyword,
                'message': log_entry.strip(),
                'line_number': log_line,
                'raw_line': log_entry.strip(),
                'is_error': 'ERROR' in keyword.upper() or 'EXCEPTION' in keyword.upper(),
                'is_critical': 'CRITICAL' in keyword.upper() or 'FATAL' in keyword.upper() or 'PANIC' in keyword.upper(),
                'is_warning': False
            }

    return None  # Return None if the log entry does not match the expected format

def find_error_and_traceback(file_path: str, error_line: int, context_lines: int = 5) -> dict:
    """
    Locates the ERROR log entry and the subsequent traceback.
    
    Args:
        file_path: Path to the log file
        error_line: Line number where the error message was found
        context_lines: Number of lines to check before and after the error line
        
    Returns:
        Dictionary with:
        - error_entry: The full ERROR log entry
        - error_line: Line number of the ERROR entry
        - traceback_start: Line number where traceback starts
        - traceback: Full traceback content
    """
    result = {
        "error_entry": None,
        "error_line": None,
        "traceback_start": None,
        "traceback": []
    }
    
    # Safety checks
    if not os.path.exists(file_path):
        return result
    
    # Look for ERROR entries and traceback patterns
    with open(file_path, 'r') as f:
        # Create a buffer to hold recent lines for context
        line_buffer = []
        in_traceback = False
        traceback_indent = 0
        
        # Start checking a few lines before the reported error
        start_line = max(1, error_line - context_lines)
        
        for i, line in enumerate(f, start=1):
            # Skip lines until we reach our target area
            if i < start_line:
                continue
                
            # We've gone too far, stop checking
            if i > error_line + 50:
                break
                
            # Add line to buffer and maintain reasonable buffer size
            line_buffer.append((i, line.rstrip()))
            if len(line_buffer) > context_lines * 2:
                line_buffer.pop(0)
            
            # Look for ERROR log entry pattern
            if "[ERROR]" in line and not result["error_entry"]:
                result["error_entry"] = line.rstrip()
                result["error_line"] = i
            
            # Look for traceback start patterns after we've seen an ERROR
            if result["error_entry"] and not in_traceback:
                if ("Traceback (most recent call last)" in line or 
                    line.startswith("  File ") or
                    "Exception: " in line):
                    result["traceback_start"] = i
                    in_traceback = True
                    # If it's an indented line, record the indent level
                    traceback_indent = len(line) - len(line.lstrip())
                    result["traceback"].append(line.rstrip())
                    continue
            
            # Collect traceback lines
            if in_traceback:
                # Check if we're still in the traceback by indent level or common patterns
                if (line.startswith(" " * traceback_indent) or
                   "File " in line or 
                   "line " in line or
                   "Exception: " in line or
                   "Error: " in line):
                    result["traceback"].append(line.rstrip())
                else:
                    # Empty line or different indent might still be part of traceback
                    if line.strip() == "" or "^" in line:
                        result["traceback"].append(line.rstrip())
                    else:
                        # We've exited the traceback
                        break
    
    return result


## Agent plugin definitions
class LisaErrorAnalyzerPlugin:
    @kernel_function(
        name="search_error",
        description="Searches for a specific error message in the log files within the configured log directory " \
        "and once found, returns the file path and line number associated with the error message in a structured format.",
    )
    def search_error(self, error_message: str, log_folder_path: str) -> List[dict]:
        """
        Searches for a specific error message in the log files log_folder_path.
        Return two types of log entries of type LogEntry: the ERROR log entry, and the entry that contains the error message.
        """
        norm_log_folder_path = os.path.normpath(log_folder_path)

        if not os.path.exists(norm_log_folder_path):
            logging.error(f"Log folder path does not exist: {norm_log_folder_path}")
            return []

        # Include line number of error_message, and metadata about the ERROR log entry.
        error_context = []

        for root, _, files in os.walk(norm_log_folder_path):
            for file in files:
                if file.endswith(FileExtensions.LOG_EXTENSION):
                    file_path = os.path.join(root, file)
                    try:
                        with open(file_path, 'r') as f:
                            for i, line in enumerate(f, start=1):
                                # First check if the error message is in the line
                                if error_message in line:
                                    # Parse the line into structured format
                                    parsed_line = parse_log_entry(line, i)
                                    
                                    # If parsing failed, create a basic entry with raw text
                                    if parsed_line is None:
                                        parsed_line = {
                                            'line_number': i,
                                            'raw_line': line.strip(),
                                            'file_path': file_path,
                                            'is_error': True
                                        }
                                    else:
                                        # Add file path to the parsed entry
                                        parsed_line['file_path'] = file_path
                                    
                                    # Add to context
                                    error_context.append(parsed_line)
                    except FileNotFoundError:
                        continue  # Skip if file is not found
                    except Exception as e:
                        continue
        print(f"Error context found with {len(error_context)} entries")
        if len(error_context) == 0:
            print("WARNING: No error context found. The error message may not be present in the logs.")
            # As a fallback, try searching for partial matches
            search_terms = error_message.split()
            if len(search_terms) > 2:  # Only try if we have multiple words
                print(f"Trying fallback search with key terms: {search_terms[:3]}")
                # Try searching for the first few terms as a substring
                partial_search = ' '.join(search_terms[:3])
                for root, _, files in os.walk(norm_log_folder_path):
                    for file in files:
                        if file.endswith(FileExtensions.LOG_EXTENSION):
                            file_path = os.path.join(root, file)
                            try:
                                with open(file_path, 'r') as f:
                                    for i, line in enumerate(f, start=1):
                                        if partial_search in line:
                                            print(f"Found partial match in {file_path} at line {i}")
                                            # Create basic entry with raw text
                                            error_context.append({
                                                'line_number': i,
                                                'raw_line': line.strip(),
                                                'file_path': file_path,
                                                'is_partial_match': True
                                            })
                                            break  # Just find the first occurrence
                            except Exception:
                                continue  # Skip problematic files
        
        # Make sure we return something, even if it's just an indication nothing was found
        if len(error_context) == 0:
            error_context = [{
                'error': 'No matching error entries found',
                'search_term': error_message,
                'searched_path': norm_log_folder_path
            }]
            
        return error_context
    
    @kernel_function(
        name="extract_segment",
        description="Extracts the call trace or relevant code segment from a file (log or code) by locating the section that contains the call trace" \
        " or error context associated with a given error message. Returns a JSON object containing the line numbers in the log and the extracted segment. " \
        "The relevant segment may start several lines before the error line, so use an offset (e.g. 20-30 lines before the error line) to capture the full content." \
        "For the call trace in the log, capture the line number corresponding to the ERROR-level log entry.",
    )
    def extract_segment(self, line_number: int, input_path: str, offset: int) -> str:
        """
        Extracts the lines of the relevant segment from the file (log or code) starting from the line number of the error message.
        offset allows the model to capture several lines before the error line to get the full context.
        """
        traceback = []
        norm_path = os.path.normpath(input_path)

        if os.path.exists(norm_path):
            traceback_start = max(0, line_number - offset)
            with open(norm_path, 'r') as f:
                for i, line in enumerate(f, start=1):
                    if traceback_start <= i <= line_number:
                        traceback.append(f"({i}): {line.rstrip()}")
                    if i > line_number:
                        break
        return "\n".join(traceback)
    
    @kernel_function(
        name="list_files",
        description="Parses the traceback for code files involved in the error. Uses the file paths from the traceback to list all the files relevant to the error." \
        "Uses the code path inputted by the user to locate the correct file paths locally, and returns the list of files that are relevant to the error.",
    )
    def list_files(self, traceback: str, code_path: str) -> List[str]:
        """
        Parses traceback for file paths and returns a list of files that are relevant to the error.
        code_path is used to locate the correct file paths locally.
        """
        files = []

        for line in traceback.splitlines():
            match = re.search(RegexPatterns.FILE_PATH_PATTERN, line)
            logging.debug(f"match: {match}")
            if match:
                logging.debug("there is match")
                file_path = match.group(1)
                local_path = map_log_path_to_local(file_path, code_path)
                if os.path.exists(local_path):
                    files.append(local_path)

        files = list(dict.fromkeys(files))

        print("\nThe agent is gathering information. Please wait...\n")
        return files    
    
    @kernel_function(
        name="locate_error_context",
        description="Locates the ERROR log entry and its associated traceback from a log file, given a line number where the error message appears. " \
        "Returns the ERROR entry's line number, content, and the full traceback that follows it."
    )
    def locate_error_context(self, file_path: str, error_line: int) -> dict:
        """
        Locates the ERROR log entry and its associated traceback.
        
        Args:
            file_path: Path to the log file
            error_line: Line number where the error message was found
            
        Returns:
            Dictionary with error information and traceback
        """
        return find_error_and_traceback(file_path, error_line)

## Path input structure
@dataclass
class InputPath:
    # Represents a file type for the path (code, log, etc.)
    type: str
    # Represents the path to the file
    value: str

class LogAgent:
    def __init__(self, url: str, key: str, **kwargs):
        self.kernel = Kernel()
    
        self.chat_completion = AzureChatCompletion(
            deployment_name="gpt-4o",
            api_key=key,
            base_url=url,
        )
        self.kernel.add_service(self.chat_completion)

        self.kernel.add_plugin(
            LisaErrorAnalyzerPlugin(),
            plugin_name="LisaErrorAnalyzer",
        )

        setup_debug_logging()

        # Enable planning -- the model decides which function to use, if any
        self.execution_settings = AzureChatPromptExecutionSettings()
        self.execution_settings.function_choice_behavior = FunctionChoiceBehavior.Auto()
        
        # Initialize chat history with truncation capability
        # This keeps the conversation size manageable while preserving important context
        self.history = ChatHistoryTruncationReducer(
            target_count=8,  # Keep 8 most recent messages
            threshold_count=4,  # Allow up to 12 messages before truncating (target + threshold)
            auto_reduce=True,  # Automatically truncate when messages exceed target+threshold
            service=self.chat_completion,
            # Preserve important technical information in truncated messages
            summarization_instructions="""Summarize the chat history while preserving all critical technical details:
            - Exact error messages and their locations
            - Thread IDs, timestamps, and command details
            - File paths, line numbers, and code references
            - Root causes identified in the analysis
            """
        )
    
    def clear_history(self):
        """
        Explicitly clear the chat history to start a fresh analysis.
        This is useful when switching to a completely different error or log set.
        """
        if hasattr(self, 'history') and self.history is not None:
            self.history.messages = []
            print("Chat history has been cleared.")
        
        if hasattr(self, 'current_error'):
            delattr(self, 'current_error')
    
    async def analyze(self, error_message: str, paths: List[InputPath]) -> str:
        # Check if we need to reset the history (e.g., for a new analysis session)
        # We keep the history if it's the same error message to maintain context
        if not hasattr(self, 'current_error') or self.current_error != error_message:
            # Start a new analysis session
            self.history.messages = []  # Clear history
            self.current_error = error_message
            
            # Load system message from file
            system_prompt_path = os.path.join(working_directory, "system_prompt.txt")
            with open(system_prompt_path, 'r') as f:
                system_message = f.read().strip()
            
            # Guide the model with system message
            self.history.add_system_message(system_message)
        else:
            # If continuing analysis on same error, add a delimiter
            self.history.add_assistant_message("--- Continuing analysis of the same error ---")

        # Display files that will be used for analysis
        assistant_message = "The following files will be used for analysis:\n"
        for path in paths:
            assistant_message += f"- {path.type}: {path.value}\n"
        self.history.add_assistant_message(assistant_message)        # Add the error message as a user message so the model knows what to search for

        # Load user message from file and format it with the error message
        user_prompt_path = os.path.join(working_directory, "user_prompt.txt")
        with open(user_prompt_path, 'r') as f:
            user_message_template = f.read().strip()
        
        # Format the user message with the error
        user_message = user_message_template.format(error_message=error_message)
        self.history.add_user_message(user_message)

        print("The agent is analyzing the error and gathering information. Please wait...")
        
        # Check if we need to reduce the chat history before sending to the model
        message_count = len(self.history.messages)
        target_count = getattr(self.history, "target_count", 8)
        threshold = getattr(self.history, "threshold_count", 4)
        
        # Show conversation stats to help understand truncation behavior
        print(f"Current conversation: {message_count} messages (target: {target_count}, threshold: {threshold})")
        
        # Trigger truncation if we're approaching the limit
        if message_count > (target_count + threshold):
            print("\n🔄 Truncating chat history...")
            print(f"Message count ({message_count}) exceeds limit ({target_count + threshold})")
            
            try:
                reduced_history = await self.history.reduce()
                
                if reduced_history:
                    print(f"✅ History reduced from {message_count} to {len(reduced_history.messages)} messages")
            except Exception as e:
                print(f"Error during truncation: {str(e)}")

        # Wait for a response from the model
        result = await self.chat_completion.get_chat_message_content(
            chat_history=self.history,
            settings=self.execution_settings,
            kernel=self.kernel,
        )

        print("\nAssistant > " + str(result))
        self.history.add_message(result)

        print("-----------------------\n")


async def main():
    print("The agent is starting up...")

    agent = LogAgent(
        url=os.getenv("AZURE_OPENAI_ENDPOINT"),
        key=os.getenv("AZURE_OPENAI_API_KEY"),
    )

    print("The agent is ready!")

    # Load test data by index - change this index to test different cases
    test_index = 8  # Change this to test different error cases (0-11 available)
    
    try:
        test_data = load_test_data_by_index(test_index)
        print(f"Loading test case {test_data}")
        
        # Extract the log folder path from the test path
        log_base_path = "C:\\Users\\t-linm\\Downloads\\log_analyzer_20250603\\log_analyzer_20250603"
        log_folder_path = os.path.join(log_base_path, test_data['path'])
        
        # Display chat history truncation configuration
        target_count = getattr(agent.history, "target_count", 8)
        threshold = getattr(agent.history, "threshold_count", 4)
        print(f"Chat history configured with target_count={target_count}, threshold_count={threshold}")
        print(f"Truncation will trigger when messages exceed {target_count + threshold}")
        
        await agent.analyze(
            error_message=test_data['error_message'],
            paths=[
                InputPath(type="log", value=log_folder_path),
                InputPath(type="code", value="C:/Users/t-linm/Documents/lisa-fork"),
            ]
        )
        
        # Final check after analysis
        final_count = len(agent.history.messages)
        print(f"\nFinal message count after analysis: {final_count}")
        
        # Display whether truncation occurred
        if final_count <= (target_count + threshold):
            print(f"Chat history is within the configured limits ({target_count + threshold})")
        else:
            print(f"Chat history exceeds the configured limits ({target_count + threshold})")
        
    except (FileNotFoundError, IndexError, ValueError) as e:
        print(f"Error loading test data: {e}")
        return


if __name__ == "__main__":
    asyncio.run(main())
