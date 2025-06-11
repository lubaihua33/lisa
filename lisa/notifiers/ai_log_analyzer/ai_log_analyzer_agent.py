import asyncio
import datetime
import logging
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
    
    logging.getLogger().addHandler(file_handler)


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
        print(f"Searching for error message: {error_message} in path: {input_path}")
        location = []

        if os.path.exists(input_path):
            print(f"Input path exists: {input_path}")
            with open(input_path, 'r') as f:
                for i, line in enumerate(f, start=1):
                    if error_message in line:
                        location.append(f"{input_path}, (line {i}): {line.strip()}")

        return location
    

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
            "You are an AI assistant that helps users find error messages in log files."
            "If the user provides an error message, call the `search_error` function with it."
        )

        assistant_message = "The following files will be used for analysis:\n"
        for path in paths:
            assistant_message += f"- {path.type}: {path.value}\n"
        self.history.add_assistant_message(assistant_message)


        # Add the error message as a user message so the model knows what to search for
        self.history.add_user_message(f"Please search for this error: {error_message}")

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
        error_message="lisa.util.TcpConnectionException: cannot connect to TCP port: [134.33.26.13:22], error code: 10061, no panic found in serial log during bootup",
        paths=[
            InputPath(type="log", value="C:/Users/t-linm/Downloads/log_analyzer_20250603/log_analyzer_20250603/20250603-153958-212-smoke_test/20250603-153958-212-smoke_test.log"),
            InputPath(type="code", value="C:/Users/t-linm/Documents/lisa-fork"),
        ]
    )


if __name__ == "__main__":
    asyncio.run(main())
