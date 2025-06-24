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
from semantic_kernel.contents.utils.author_role import AuthorRole
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
        # Find the index of the anchor directory
        anchor_index = parts.index(anchor_dir)
        # Join all parts after the anchor directory
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
    """
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

        return structured.to_dict()

    return None  # Return None if the log entry does not match the expected format


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

        logging.debug(f"Searching for error message: {error_message} in folder: {norm_log_folder_path}")
        # Search through all log files in the directory
        for root, _, files in os.walk(norm_log_folder_path):
            for file in files:
                if file.endswith('.log'):
                    file_path = os.path.join(root, file)
                    try:
                        with open(file_path, 'r') as f:
                            for i, line in enumerate(f, start=1):
                                parsed_line = parse_log_entry(line, i)

                                # Record the line with ERROR log entry
                                if parsed_line.get('is_error', False):
                                    # Found line with ERROR log level
                                    error_context.append(parsed_line)
                                
                                # Record the line if it contains the error message
                                if parsed_line.get('raw_line') in line:
                                    error_context.append(parsed_line)

                    except FileNotFoundError:
                        continue  # Skip if file is not found
                    except Exception as e:
                        # print(f"Error reading file {file_path}: {e}")
                        print("Skipping...")
                        continue
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

        print("\nThe agent is gathering information. Please wait...")
        return files    
    
    # @kernel_function(
    #     name="parse_logs",
    #     description="Parses the log file content into structured log entries up until the ERROR log entry. Only limits parsing of the last MAX_RECENT_COMMANDS" \
    #     "entries of the same thread as the ERROR entry to prevent excessive memory usage. " \
    #     "Extracts: timestamp, thread number, log level, component, and message."
    # )
    # def parse_logs(self, file_path: str) -> List[dict]:
    #     """
    #     Parses the log entries into structured LogEntry objects up until the error log entry. Only parse the last MAX_RECENT_COMMANDS entries of the same thread.
    #     input_path is the path to the log file to be parsed.
    #     """
    #     parsed_entries = []
    #     norm_path = os.path.normpath(file_path)
    #     logging.debug(f"Parsing log file: {norm_path}")

    #     if os.path.exists(norm_path):
    #         with open(norm_path, 'r') as f:
    #             for i, line in enumerate(f, start=1):
    #                 # Parse each line into a LogEntry object
    #                 entry = parse_log_entry(line, i)
    #                 if entry:
    #                     parsed_entries.append(entry)
    #                     logging.debug(f"Parsed entry: {i} - {entry['raw_line']}")
    #                     if entry.get('is_error', False):
    #                         break  # Stop parsing if an error entry is found
    #     return parsed_entries
    
    # @kernel_function(
    #     name="filter_by_thread_id",
    #     description="Parses the log entries produced by parse_logs() and filters them by thread number."
    #     "Limit log entries to MAX_RECENT_COMMANDS." \
    # )
    # def filter_by_thread_id(self, error_thread_id: str, parsed_entries: List[dict]) -> List[dict]:
    #     """
    #     Filters the parsed log entries by thread number.
        
    #     Args:
    #         thread_number: The thread number to filter by
    #         parsed_entries: List of all parsed LogEntry objects
            
    #     Returns:
    #         List of LogEntry objects that match the specified thread number
    #     """
    #     if not error_thread_id:
    #         return []

    #     # Filter entries by thread number
    #     filtered_entries = [
    #         entry for entry in parsed_entries 
    #         if entry.get('thread_number') == error_thread_id
    #     ]

    #     # Limit to MAX_RECENT_COMMANDS
    #     return filtered_entries[-AnalysisLimits.MAX_RECENT_COMMANDS:]

        

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
    
    async def analyze(self, error_message: str, paths: List[InputPath]) -> str:
        self.history = ChatHistory()

        # Load system message from file
        system_prompt_path = os.path.join(working_directory, "system_prompt.txt")
        with open(system_prompt_path, 'r') as f:
            system_message = f.read().strip()
        
        # Guide the model with system message
        self.history.add_system_message(system_message)

        assistant_message = "The following files will be used for analysis:\n"
        for path in paths:
            assistant_message += f"- {path.type}: {path.value}\n"
        self.history.add_assistant_message(assistant_message)        # Add the error message as a user message so the model knows what to search for

        self.history.add_user_message(f"Please search for this error: {error_message} in the logs. Troubleshoot the error, identify the root causes, and suggest the best course of action to resolve the issue. " )

        print("The agent is analyzing the error and gathering information. Please wait...")

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
    test_index = 10  # Change this to test different error cases (0-11 available)
    
    try:
        test_data = load_test_data_by_index(test_index)
        print(f"Loading test case {test_index}: {test_data['path']}")
        
        # Extract the log folder path from the test path
        log_base_path = "C:\\Users\\t-linm\\Downloads\\log_analyzer_20250603\\log_analyzer_20250603"
        log_folder_path = os.path.join(log_base_path, test_data['path'])
        
        await agent.analyze(
            error_message=test_data['error_message'],
            paths=[
                InputPath(type="log", value=log_folder_path),
                InputPath(type="code", value="C:/Users/t-linm/Documents/lisa-fork"),
            ]
        )
        
    except (FileNotFoundError, IndexError, ValueError) as e:
        print(f"Error loading test data: {e}")
        return


if __name__ == "__main__":
    asyncio.run(main())
