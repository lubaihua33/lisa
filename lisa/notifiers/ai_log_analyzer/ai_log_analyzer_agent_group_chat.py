import asyncio
import datetime
import logging
import re
import os
import json
import sys
from enum import Enum
from rapidfuzz import fuzz
from typing import List
from dataclasses import dataclass
from dotenv import load_dotenv
from semantic_kernel import Kernel
from semantic_kernel.utils.logging import setup_logging
from semantic_kernel.functions import kernel_function, KernelArguments
from semantic_kernel.agents import ChatCompletionAgent
from semantic_kernel.connectors.ai.function_choice_behavior import FunctionChoiceBehavior
from semantic_kernel.connectors.ai.open_ai import AzureChatCompletion

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

class Thresholds:
    FUZZY_THRESHOLD = 90  # Fuzzy matching threshold for error messages
    CONTEXT_THRESHOLD = 95
    VERBOSITY_LENGTH_THRESHOLD = 1000  # Max length for verbose log messages
    


class RegexPatterns:
    """Regex patterns for log parsing"""
    # LISA log format: timestamp[thread][level] component message
    LISA_LOG_PATTERN = r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\[(\d+)\]\[([^\]]+)\]\s+([^\s]+)\s+(.*)$'

    FILE_PATH_PATTERN = r'File "([^"]+)"'
    
    # Command ID pattern for extracting command IDs from log messages
    COMMAND_ID_PATTERN = r'cmd_id:(\w+)'
    

class FileExtensions:
    """File extensions for log files"""
    LOG_EXTENSION = '.log'
    SERIAL_LOG_EXTENSION = '_serial_console.log'



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

class VerbosityFilter(logging.Filter):
    """
    A filter to truncate verbose log messages rather than excluding them entirely.
    Specifically designed for OpenAI API logs to show request/response structure
    without the full content payload.
    """
    def __init__(self):
        super().__init__()
        # Patterns that indicate verbose messages we want to truncate
        self.verbose_patterns = {
            "Request options:": 200,   # Truncate after 200 chars 
            "Response body:": 300,     # Truncate after 300 chars
            '"content": "': 100,       # Truncate content fields
            '"messages": [': 150,      # Truncate message arrays
            '"input": "': 100,         # Truncate input fields
            '"function_call": {': 150, # Truncate function calls
            '"choices": [': 200,       # Truncate choices array
        }
        
    def filter(self, record):
        # Skip truncation for non-openai messages
        if not record.name.startswith("openai"):
            return True
            
        # Only process debug level messages from openai
        if record.levelno <= logging.DEBUG:
            message = record.getMessage()
            
            # Check if message is very long (exceeds threshold)
            if len(message) > Thresholds.VERBOSITY_LENGTH_THRESHOLD:
                # Check for patterns that should be truncated
                for pattern, max_length in self.verbose_patterns.items():
                    if pattern in message:
                        # Find the pattern position
                        pattern_pos = message.find(pattern)
                        # Keep the header and some context, then add truncation notice
                        truncated_msg = f"{message[:pattern_pos + max_length]}... [truncated {len(message) - pattern_pos - max_length} chars]"
                        
                        record.msg = truncated_msg
                        record.args = ()
                        break

        return True

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

    # Create console handler for INFO and above
    # console_handler = logging.StreamHandler()
    # console_handler.setLevel(logging.INFO)
    # console_handler.setFormatter(formatter)

    # Remove any existing handlers except the file handler
    for handler in logging.getLogger().handlers[:]:
        logging.getLogger().removeHandler(handler)
    
    # Add both file and console handlers
    logging.getLogger().addHandler(file_handler)
    # logging.getLogger().addHandler(console_handler)
    
    # Add verbosity filter to truncate verbose messages
    verbosity_filter = VerbosityFilter()
    logging.getLogger().addFilter(verbosity_filter)
    
    # # Enable detailed logging for Semantic Kernel components
    # logging.getLogger("semantic_kernel").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors.ai").setLevel(logging.DEBUG)
    # logging.getLogger("semantic_kernel.connectors.ai.open_ai").setLevel(logging.DEBUG)
    
    # # Enable HTTP request logging to capture all LLM requests
    # logging.getLogger("httpcore").setLevel(logging.DEBUG)
    # logging.getLogger("httpx").setLevel(logging.DEBUG)
    # logging.getLogger("openai").setLevel(logging.DEBUG)
    
    logging.info(f"Debug logging configured. Writing to: {tracing_filepath}")


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
    
def parse_lisa_log_entry(log_entry: str, log_line: int) -> LogEntry | None:
    """
    Parses a single LISA log entry string into a structured LogEntry object.
    
    Args:
        log_entry: A single line from the log file.
        log_line: The line number of this entry in the log file.
        
    Returns:
        LogEntry object with parsed components: timestamp, thread number, log level, component, message.
        Returns None if the entry doesn't match the expected format.
    """
    # Try to match the LISA log pattern
    match = re.match(RegexPatterns.LISA_LOG_PATTERN, log_entry.strip())
    if match:
        timestamp, thread_number, log_level, component, message = match.groups()
        
        # Check for command ID in the message
        cmd_id = None
        cmd_match = re.search(RegexPatterns.COMMAND_ID_PATTERN, message)
        if cmd_match:
            cmd_id = cmd_match.group(1)
            
        return LogEntry(
            timestamp=timestamp,
            thread_number=thread_number,
            log_level=log_level,
            component=component,
            cmd_id=cmd_id,
            message=message,
            line_number=log_line,
            raw_line=log_entry.strip()
        )
    
    # For error messages that don't match the standard format but contain ERROR/CRITICAL keywords
    for keyword in ErrorKeywords.ALL_ERROR_PATTERNS:
        if keyword in log_entry.upper():
            logging.debug(f"Found keyword {keyword} in log: {log_entry}")
            return LogEntry(
                log_level=LogLevel.ERROR.value,
                message=log_entry.strip(),
                line_number=log_line,
                raw_line=log_entry.strip(),
                is_error=True
            )

    # If no pattern matches, return a basic entry
    return LogEntry(
        message=log_entry.strip(),
        line_number=log_line,
        raw_line=log_entry.strip()
    )


## Agent plugin definitions
class LisaErrorAnalyzerPlugin:
    @kernel_function(
        name="search_logs",
        description="Search function that looks for error messages in both standard log files and serial console logs."
    )
    def search_logs(self, error_message: str, log_folder_path: str) -> dict:
        """
        Searches for a specific error message in both standard log files and serial console logs.
        
        This unified function combines the capabilities of search_error and search_serial_logs,
        returning structured results for both types of logs.
        
        Args:
            error_message: The error message or keywords to search for
            log_folder_path: The path to the log directory to search in
            
        Returns:
            Dictionary containing structured results from both standard and serial console logs
        """
        norm_log_folder_path = os.path.normpath(log_folder_path)

        if not os.path.exists(norm_log_folder_path):
            logging.error(f"Log folder path does not exist: {norm_log_folder_path}")
            return {"standard_context": [], "serial_context": []}

        # Combined results
        log_context = {
            "standard_context": [],
            "serial_context": []
        }

        # Search both standard logs and serial logs
        for root, _, files in os.walk(norm_log_folder_path):
            for file in files:
                file_path = os.path.join(root, file)
                is_standard_log = file.endswith(FileExtensions.LOG_EXTENSION)
                is_serial_log = file.endswith(FileExtensions.SERIAL_LOG_EXTENSION)
                
                if not (is_standard_log or is_serial_log):
                    continue  # Skip non-log files
                    
                try:
                    with open(file_path, 'r') as f:
                        for i, line in enumerate(f, start=1):
                            # Process standard logs
                            if is_standard_log and not is_serial_log:
                                # Use fuzzy matching for standard logs
                                similarity = fuzz.ratio(line.strip().lower(), error_message.strip().lower())
                                if similarity >= Thresholds.FUZZY_THRESHOLD:
                                    logging.debug(f"Found error message in {file_path} at line {i} with similarity {similarity}")
                                    
                                    # Parse the line into structured format
                                    parsed_line = parse_lisa_log_entry(line, i)
                                    
                                    # Add metadata
                                    parsed_dict = parsed_line.to_dict()
                                    parsed_dict['file_path'] = file_path
                                    parsed_dict['similarity'] = similarity
                                    parsed_dict['is_exact_match'] = similarity > 95
                                    
                                    # Add to context
                                    log_context["standard_context"].append(parsed_dict)
                            
                            # Process serial logs
                            elif is_serial_log:
                                partial_similarity = fuzz.partial_ratio(line.strip().lower(), error_message.strip().lower())
                                if partial_similarity >= Thresholds.CONTEXT_THRESHOLD:
                                    log_context["serial_context"].append({
                                        'line_number': i,
                                        'raw_line': line.strip(),
                                        'file_path': file_path,
                                        'similarity': partial_similarity
                                    })
                except Exception as e:
                    logging.error(f"Error processing file {file_path}: {str(e)}")
                    continue

        logging.info(f"log_context: {log_context}")

        return log_context
    
    @kernel_function(
        name="read_text_file",
        description="Extracts the call trace or relevant code segment from a file (log or code) by locating the section that contains the call trace" \
        " or error context associated with a given error message. Returns a string containing the line numbers in the log and the extracted segment. " \
        "The relevant segment may start several lines before the error line, so use an offset (e.g. 20-30 lines before the error line) to capture the full content." \
        "For the call trace in the log, capture the line number corresponding to the ERROR-level log entry.",
    )
    def read_text_file(self, start_line_offset: int, input_path: str, line_count: int) -> str:
        """
        Extracts the lines of the relevant segment from the file (log or code) starting from the line number of the error message.
        offset allows the model to capture several lines before the error line to get the full context.
        """
        traceback = []
        norm_path = os.path.normpath(input_path)

        if os.path.exists(norm_path):
            traceback_start = max(0, start_line_offset )
            traceback_end = traceback_start + line_count
            with open(norm_path, 'r') as f:
                for i, line in enumerate(f, start=1):
                    if traceback_start <= i <= traceback_end:
                        traceback.append(f"({i}): {line.rstrip()}")
                    if i > traceback_end:
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
            if match:
                file_path = match.group(1)
                local_path = map_log_path_to_local(file_path, code_path)
                if os.path.exists(local_path):
                    files.append(local_path)

        files = list(dict.fromkeys(files))

        print("\nThe agent is gathering information. Please wait...\n")
        return files
    

## Path input structure
@dataclass
class InputPath:
    # Represents a file type for the path (code, log, etc.)
    type: str
    # Represents the path to the file
    value: str

def create_chat_completion_agent(url: str, key: str, name: str, description: str, instructions: str = None):
    """Create a ChatCompletionAgent with the specified configuration."""
    # Create chat completion service for the agent
    chat_completion = AzureChatCompletion(
        deployment_name="gpt-4o",
        api_key=key,
        base_url=url,
    )
    
    # Create and return the agent
    agent = ChatCompletionAgent(
        service=chat_completion,
        name=name,
        description=description,
        instructions=instructions,
        plugins=[LisaErrorAnalyzerPlugin()]
    )
    
    return agent


class LogSearchAgent:
    def __init__(self, url: str, key: str):
        system_prompt_path = os.path.join(working_directory, "prompts", "log_search_system_prompt.txt")
        with open(system_prompt_path, 'r') as f:
            instructions = f.read().strip()
            
        self._agent = create_chat_completion_agent(
            url=url,
            key=key,
            name="LogSearchAgent",
            description="Searches and analyzes log files for error patterns and diagnostic information.",
            instructions=instructions
        )
        
        setup_debug_logging()
    
    async def invoke(self, prompt: str) -> str:
        """Invoke the log search agent with a prompt and return the response."""
        async for response in self._agent.invoke(messages=prompt):
            return response.content
        return "No response generated"


class CodeSearchAgent:
    def __init__(self, url: str, key: str):
        system_prompt_path = os.path.join(working_directory, "prompts", "code_search_system_prompt.txt")
        with open(system_prompt_path, 'r') as f:
            instructions = f.read().strip()
            
        self._agent = create_chat_completion_agent(
            url=url,
            key=key,
            name="CodeSearchAgent", 
            description="Examines source code files and analyzes implementations related to errors.",
            instructions=instructions
        )
        
        setup_debug_logging()
    
    async def invoke(self, prompt: str) -> str:
        """Invoke the code search agent with a prompt and return the response."""
        async for response in self._agent.invoke(messages=prompt):
            return response.content
        return "No response generated"


async def main():
    """
    Main function that orchestrates a simple multi-agent log analysis workflow.
    
    Uses specialized agents to analyze LISA test errors by combining log analysis 
    and code inspection capabilities.
    """
    print("The agents are starting up...")

    # Create specialized agents
    log_search_agent = LogSearchAgent(
        url=os.getenv("AZURE_OPENAI_ENDPOINT"),
        key=os.getenv("AZURE_OPENAI_API_KEY"),
    )
    
    code_search_agent = CodeSearchAgent(
        url=os.getenv("AZURE_OPENAI_ENDPOINT"),
        key=os.getenv("AZURE_OPENAI_API_KEY"),
    )

    print("The agents are ready!")

    # Load test case and set up paths
    test_index = 8
    
    try:
        test_data = load_test_data_by_index(test_index)
        print(f"\nLoading test case {test_data}")
        
        root_path = "C:\\Users\\t-linm\\Downloads\\log_analyzer_20250603\\log_analyzer_20250603"
        log_folder_path = os.path.join(root_path, test_data['path'])
        code_path = "C:/Users/t-linm/Documents/lisa-fork"
        
        # Create analysis prompt
        error_message = test_data['error_message']
        analysis_prompt = f"""I need to analyze this error from LISA tests: "{error_message}"
        
        Available resources:
        - Log directory: {log_folder_path}
        - Code repository: {code_path}
        
        Please identify the root cause of this error and provide an analysis.
        """
        
        print("\nStarting analysis. Please wait...\n")
        
        # Use log search agent for analysis
        print("=== Log Search Agent Analysis ===")
        log_result = await log_search_agent.invoke(analysis_prompt)
        print(log_result)
        
        # Use code search agent for analysis  
        print("\n=== Code Search Agent Analysis ===")
        code_result = await code_search_agent.invoke(analysis_prompt)
        print(code_result)
        
        print("\n=== Analysis Complete ===")
        
    except (FileNotFoundError, IndexError, ValueError) as e:
        print(f"Error loading test data: {e}")
        return


if __name__ == "__main__":
    asyncio.run(main())
