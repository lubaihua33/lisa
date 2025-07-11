# Copyright (c) Microsoft. All rights reserved.

import sys
import os
from abc import ABC
from collections.abc import AsyncIterable, Awaitable, Callable
from enum import Enum
from typing import TYPE_CHECKING, Any, Literal

from semantic_kernel.connectors.ai.chat_completion_client_base import ChatCompletionClientBase
from semantic_kernel.contents.utils.author_role import AuthorRole

if sys.version_info >= (3, 12):
    from typing import override  # pragma: no cover
else:
    from typing_extensions import override  # pragma: no cover

from semantic_kernel.agents import ChatCompletionAgent
from semantic_kernel.contents import ChatMessageContent
from semantic_kernel.functions import KernelArguments
from semantic_kernel.kernel import Kernel

if TYPE_CHECKING:
    from semantic_kernel.agents import AgentResponseItem, AgentThread


class AIServices(str, Enum):
    """Enum for supported AI chat completion services.

    For service specific settings, refer to this documentation:
    https://learn.microsoft.com/en-us/semantic-kernel/concepts/ai-services/chat-completion
    """

    OPENAI = "openai"
    AZURE_OPENAI = "azure_openai"


class LogAnalyzerAgentBase(ChatCompletionAgent, ABC):
    """
    Custom agent base class for LISA log analysis agents.
    
    Provides consistent message handling, AI service setup, and conversation management
    for all log analyzer agents (LogSearchAgent, CodeSearchAgent, etc.).
    
    Features:
    - Automatic message normalization (strings -> ChatMessageContent)
    - Azure OpenAI and OpenAI service support
    - Context preservation and filtering
    - Streaming response handling
    - Additional context injection capabilities
    """

    def _create_ai_service(
        self, 
        service: AIServices = AIServices.AZURE_OPENAI, 
        instruction_role: Literal["system", "developer"] = "system"
    ) -> ChatCompletionClientBase:
        """Create an AI service for the log analyzer agent.

        Note: For Azure OpenAI, ensure the following environment variables are present:
        - AZURE_OPENAI_ENDPOINT
        - AZURE_OPENAI_API_KEY
        - AZURE_OPENAI_CHAT_DEPLOYMENT_NAME (optional, defaults to gpt-4o)
        - AZURE_OPENAI_API_VERSION (optional)

        For OpenAI, ensure the following environment variables are present:
        - OPENAI_API_KEY
        - OPENAI_CHAT_MODEL_ID

        Args:
            service (AIServices): The AI service to use (Azure OpenAI or OpenAI).
            instruction_role (str): The role of the instruction in the chat completion request.
                Can be either "system" or "developer". Defaults to "system".

        Returns:
            ChatCompletionClientBase: The configured AI service instance.

        Raises:
            ValueError: If an unsupported service is specified.
        """

        match service:
            case AIServices.AZURE_OPENAI:
                from semantic_kernel.connectors.ai.open_ai import AzureChatCompletion

                return AzureChatCompletion(
                    deployment_name=os.getenv("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME", "gpt-4o"),
                    api_key=os.getenv("AZURE_OPENAI_API_KEY"),
                    base_url=os.getenv("AZURE_OPENAI_ENDPOINT"),
                    instruction_role=instruction_role
                )
            case AIServices.OPENAI:
                from semantic_kernel.connectors.ai.open_ai import OpenAIChatCompletion

                return OpenAIChatCompletion(instruction_role=instruction_role)
            case _:
                raise ValueError(
                    f"Unsupported service: {service}. Supported services are: {', '.join([s.value for s in AIServices])}"
                )

    @override
    async def invoke(
        self,
        *,
        messages: str | ChatMessageContent | list[str | ChatMessageContent] | None = None,
        thread: "AgentThread | None" = None,
        on_intermediate_message: Callable[[ChatMessageContent], Awaitable[None]] | None = None,
        arguments: KernelArguments | None = None,
        kernel: "Kernel | None" = None,
        additional_context: str | None = None,
        log_folder_path: str | None = None,
        code_path: str | None = None,
        **kwargs: Any,
    ) -> AsyncIterable["AgentResponseItem[ChatMessageContent]"]:
        """
        Invoke the log analyzer agent with enhanced context handling.
        
        This method extends the base invoke functionality with log analyzer-specific
        features like automatic context injection and path information.

        Args:
            messages: The input messages (string, ChatMessageContent, or list of either).
            thread: Optional agent thread for conversation management.
            on_intermediate_message: Callback for intermediate message handling.
            arguments: Kernel arguments for function execution.
            kernel: Kernel instance for function execution.
            additional_context: Extra context to inject into the conversation.
            log_folder_path: Path to log directory (automatically injected as context).
            code_path: Path to code repository (automatically injected as context).
            **kwargs: Additional arguments passed to the base invoke method.

        Yields:
            AgentResponseItem[ChatMessageContent]: Streaming responses from the agent.
        """
        # Normalize input messages to consistent format
        normalized_messages = self._normalize_messages(messages)

        # Inject log analyzer-specific context
        context_parts = []
        
        if additional_context:
            context_parts.append(f"Additional context: {additional_context}")
            
        if log_folder_path:
            context_parts.append(f"Log directory available: {log_folder_path}")
            
        if code_path:
            context_parts.append(f"Code repository available: {code_path}")
            
        if context_parts:
            context_message = "Available resources and context:\n" + "\n".join(context_parts)
            normalized_messages.append(
                ChatMessageContent(role=AuthorRole.USER, content=context_message)
            )

        # Filter out empty or function-only messages to avoid polluting context
        # This is crucial for log analysis where function call results can be verbose
        messages_to_pass = [m for m in normalized_messages if m.content and m.content.strip()]

        # Call the underlying ChatCompletionAgent with cleaned messages
        async for response in super().invoke(
            messages=messages_to_pass,  # type: ignore
            thread=thread,
            on_intermediate_message=on_intermediate_message,
            arguments=arguments,
            kernel=kernel,
            **kwargs,
        ):
            yield response

    def _normalize_messages(
        self, messages: str | ChatMessageContent | list[str | ChatMessageContent] | None
    ) -> list[ChatMessageContent]:
        """
        Normalize various message input formats to a consistent list of ChatMessageContent.
        
        This method handles the complexity of different input formats that might be passed
        to log analyzer agents, ensuring consistent processing regardless of input type.

        Args:
            messages: Input messages in various formats (None, string, ChatMessageContent, or lists).

        Returns:
            list[ChatMessageContent]: Normalized list of ChatMessageContent objects.
        """
        if messages is None:
            return []
            
        if isinstance(messages, (str, ChatMessageContent)):
            messages = [messages]
            
        normalized: list[ChatMessageContent] = []
        
        for msg in messages:
            if isinstance(msg, str):
                # Convert strings to USER role messages
                normalized.append(ChatMessageContent(role=AuthorRole.USER, content=msg))
            else:
                # Preserve existing ChatMessageContent as-is
                normalized.append(msg)
                
        return normalized

    async def invoke_simple(self, prompt: str) -> str:
        """
        Simplified invoke method that returns just the content string.
        
        This is a convenience method for simple use cases where you just want
        the AI's response as a string without dealing with streaming or complex types.

        Args:
            prompt: Simple string prompt to send to the agent.

        Returns:
            str: The agent's response content, or a default message if no response.
        """
        async for response in self.invoke(messages=prompt):
            if response.content and response.content.content:
                return response.content.content
        return "No response generated"

    def _get_working_directory(self) -> str:
        """Get the working directory for the log analyzer."""
        return os.path.dirname(os.path.realpath(__file__))

    def _load_system_prompt(self, prompt_filename: str) -> str:
        """
        Load system prompt from the prompts directory.
        
        Args:
            prompt_filename: Name of the prompt file (e.g., "log_search_system_prompt.txt").
            
        Returns:
            str: Contents of the prompt file.
            
        Raises:
            FileNotFoundError: If the prompt file doesn't exist.
        """
        working_directory = self._get_working_directory()
        prompt_path = os.path.join(working_directory, "prompts", prompt_filename)
        
        try:
            with open(prompt_path, 'r', encoding='utf-8') as f:
                return f.read().strip()
        except FileNotFoundError:
            raise FileNotFoundError(f"System prompt file not found: {prompt_path}")
