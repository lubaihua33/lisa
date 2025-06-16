import asyncio
import datetime
import logging
import re
import os

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
from semantic_kernel.connectors.ai.open_ai.prompt_execution_settings.azure_chat_prompt_execution_settings import (
    AzureChatPromptExecutionSettings,
)

load_dotenv()

working_directory = os.path.dirname(os.path.realpath(__file__))

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

def map_log_path_to_local(log_path: str, local_root: str, anchor_dir: str="lisa") -> str:
    """
    Maps a file path in the traceback to a local file system path based on the provided local root directory.
    The log_path is expected to be relative to the anchor_dir, which is typically the 'lisa' directory. Skips the mapping 
    if the log_path does not contain the anchor_dir.
    """
    norm_log_path = os.path.normpath(log_path)
    norm_local_root = os.path.normpath(local_root)

    parts = norm_log_path.split(os.sep)
    if anchor_dir in parts:
        # Find the index of the anchor directory
        anchor_index = parts.index(anchor_dir)
        relative_path = os.path.join(*parts[anchor_index + 1:])  # Get the path after the anchor directory
        local = os.path.join(norm_local_root, relative_path)
        return os.path.normpath(local)
    else:
        return ""



class FileSearchPlugin:
    @kernel_function(
        name="search_error",
        description="Searches log file for a specific error message " \
        "given by the user and returns the matching file path with the line numbers in a structured format.",
    )
    def search_error(self, error_message: str, input_path: str) -> List[str]:
        """
        The model will recognize the error as error_message, and path as path, then pass the values as arguments to the function.
        """ 
        # print(f"\nSearching for error message: {error_message} in path: {input_path}")
        location = []
        norm_path = os.path.normpath(input_path)

        if os.path.exists(norm_path):
            # print(f"\nInput path exists: {norm_path}")
            with open(norm_path, 'r') as f:
                for i, line in enumerate(f, start=1):
                    if error_message in line:
                        location.append(f"{norm_path}, (line {i}): {line.strip()}")

        return location
    
    @kernel_function(
        name="extract_segment",
        description="Extracts the call trace or relevant code segment from a file (log or code) by locating the section that contains the call trace" \
        " or error context associated with a given error message. Returns a JSON object containing the line numbers in the log and the extracted segment. " \
        "The relevant segment may start several lines before the error line, so use an offset (e.g. 10-20 lines before the error line) to capture the full content.",
    )
    def extract_segment(self, line_number: int, input_path: str, offset: int) -> str:
        """
        Extracts the lines of the relevant segment from the file (log or code) starting from the line number of the error message.
        The offset parameter allows the model to capture several lines before the error line to get the full context.
        """
        # print(f"\nExtracting error trace from line {line_number} in path: {input_path} with offset: {offset}")
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
        Parses the traceback for file paths and returns a list of files that are relevant to the error.
        The code_path parameter is used to locate the correct file paths locally.
        """
        # print(f"\nListing files from traceback: {traceback}\n with code path: {code_path}")
        files = []

        # Split the traceback into lines and look for file paths
        for line in traceback.splitlines():
            match = re.search(r'File "([^"]+)"', line)
            if match:
                file_path = match.group(1)
                local_path = map_log_path_to_local(file_path, code_path)
                # print(f"Found file path: {local_path}, mapped to local path: {local_path}")
                if os.path.exists(local_path):
                    files.append(local_path)
        print(f"\nFiles found in traceback: {files}")
        return files

@dataclass
class InputPath:
    # Represents a file type for the path (code, log, etc.)
    type: str
    # Represents the path to the file
    value: str

class LogAgent:
    def __init__(self, url: str, key: str, **kwargs):
        self.kernel = Kernel()

        # Add Azure OpenAI chat completion service for user-agent interaction
        self.chat_completion = AzureChatCompletion(
            deployment_name="gpt-4o",
            api_key=os.getenv("AZURE_OPENAI_API_KEY"),
            base_url=os.getenv("AZURE_OPENAI_ENDPOINT"),
        )
        self.kernel.add_service(self.chat_completion)
        self.kernel.add_plugin(
            FileSearchPlugin(),
            plugin_name="Search",
        )

        setup_debug_logging()

        # Enable planning -- the model decides which function to use, if any
        self.execution_settings = AzureChatPromptExecutionSettings()
        self.execution_settings.function_choice_behavior = FunctionChoiceBehavior.Auto()
    
    async def analyze(self, error_message: str, paths: List[InputPath]) -> str:
        # Create a history of the conversation
        self.history = ChatHistory()
        # Guide the model -- add more context as functions are added
        self.history.add_system_message(
            "You are an AI assistant that helps users analyze error messages from LISA logs. Your tasks include:" \
            "1. Searching for the error message in the provided log files when the user provides one." \
            "2. Extracting the traceback or relevant code segment from the log file, considering that the traceback may start several lines before the error line." \
            "3. Listing the files that are relevant to the error based on the traceback, relative to the local machine." \
            "4. Analyzing the relevant code segment from the file, starting from the most recent file in the traceback." \
            "5. Providing a summary of the error, the relevant code segment, and suggestions to troubleshoot the issue." \
            "You will use the provided log files and code paths to perform these tasks." \
        )

        assistant_message = "The following files will be used for analysis:\n"
        for path in paths:
            assistant_message += f"- {path.type}: {path.value}\n"
        self.history.add_assistant_message(assistant_message)

        # Add the error message as a user message so the model knows what to search for
        self.history.add_user_message(f"Please search for this error: {error_message}")

        print("The agent is analyzing the error and gathering information. Please wait...")

        # Get response from the AI -- which will decide which function to call from "settings"
        result = await self.chat_completion.get_chat_message_content(
            chat_history=self.history,
            settings=self.execution_settings,
            kernel=self.kernel,
        )
        print("\nAssistant > " + str(result))
        self.history.add_message(result)
        print("-----------------------\n")


async def main():
    print("AI agent is starting up...")

    agent = LogAgent(
        url=os.getenv("AZURE_OPENAI_ENDPOINT"),
        key=os.getenv("AZURE_OPENAI_API_KEY"),
    )

    print("The agent is ready!")

    await agent.analyze(
        error_message="AssertionError: [nvme devices count should be equal to [vCPU/8].] Expected <['/dev/nvme1n1', '/dev/nvme2n1', '/dev/nvme3n1', '/dev/nvme4n1']> to be of length <16>, but was <4>.",
        paths=[
            InputPath(type="log", value="C:\\Users\\t-linm\\Downloads\\log_analyzer_20250603\\log_analyzer_20250603\\20250603-163353-041-verify_nvme_basic\\20250603-163353-041-verify_nvme_basic.log"),
            InputPath(type="code", value="C:/Users/t-linm/Documents/lisa-fork"),
        ]
    )


if __name__ == "__main__":
    asyncio.run(main())
