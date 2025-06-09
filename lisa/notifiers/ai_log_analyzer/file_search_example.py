import asyncio
import os
from typing import List

from dotenv import load_dotenv
from semantic_kernel import Kernel
from semantic_kernel.functions import kernel_function
from semantic_kernel.connectors.memory.in_memory import InMemoryVectorStore
from semantic_kernel.connectors.ai.function_choice_behavior import FunctionChoiceBehavior
from semantic_kernel.contents.chat_history import ChatHistory
from semantic_kernel.connectors.ai.open_ai import AzureOpenAISettings, AzureChatCompletion, OpenAITextEmbedding

# This enables planning
from semantic_kernel.connectors.ai.open_ai.prompt_execution_settings.azure_chat_prompt_execution_settings import (
    AzureChatPromptExecutionSettings,
)

load_dotenv()

class FileSearchPlugin:
    @kernel_function(
        name="search_error",
        description="Searches log files for a specific error message " \
        "given by the user and returns the matching file paths with their line numbers in a structured format.",
    )
    def search_error(self, error_message: str) -> List[str]:
        """
        The model will recognize whether a message is an error message or not, and pass the value as an argument to the function.
        """
        paths = []
        base_directory = os.path.join(os.path.dirname(os.path.realpath(__file__)),
            "test_logs",
        )
        
        for root, _, files in os.walk(base_directory):
            # Ignore directories that end with serial_log
            if not root.lower().endswith("serial_log"):
                for file in files:
                    if file.endswith(".log"):
                        path = os.path.join(root, file)
                        try:
                            with open(path, 'r') as f:
                                for i, line in enumerate(f, start=1):
                                    if error_message in line:
                                        paths.append(f"{path}, (line {i}): {line.strip()}")
                        except FileNotFoundError:
                            continue
                        except Exception as e:
                            print(f"Skipping...")
        return paths


async def main():
    print("AI agent is starting up...")

    kernel = Kernel()

    # Add Azure OpenAI chat completion service for user-agent interaction
    chat_completion = AzureChatCompletion(
        deployment_name="gpt-4o",
        api_key=os.getenv("AZURE_OPENAI_API_KEY"),
        base_url=os.getenv("AZURE_OPENAI_ENDPOINT"),
    )
    
    kernel.add_service(chat_completion)

    # Add plugin to kernel
    kernel.add_plugin(
        FileSearchPlugin(),
        plugin_name="Search",
    )

    # Enable planning -- the model decides which function to use, if any
    execution_settings = AzureChatPromptExecutionSettings()
    execution_settings.function_choice_behavior = FunctionChoiceBehavior.Auto()

    # Create a history of the conversation
    history = ChatHistory()

    # Guide the model
    history.add_system_message("You are an AI assistant that helps users find error messages in log files."
                               "If the user provides an error message, call the `search_error` function with it."
    )

    user_input = None
    while True:
        user_input = input("User > ")

        if user_input == "exit":
            break
        
        history.add_user_message(user_input)

        # Get response from the AI -- which will decide which function to call from "settings"
        result = await chat_completion.get_chat_message_content(
            chat_history=history,
            settings=execution_settings,
            kernel=kernel,
        )

        print("Assistant > " + str(result))

        history.add_message(result)

    ## 2nd iteration
    # embedding_gen = OpenAITextEmbedding(
    #     ai_model_id="text-embedding-ada-002",
    #     api_key=os.getenv("AZURE_OPENAI_API_KEY"),
    # )

    # kernel.add_service(embedding_gen)

    # vector_store = InMemoryVectorStore()

    # expand_log_files()


    # Upsert vector store with log files


if __name__ == "__main__":
    asyncio.run(main())