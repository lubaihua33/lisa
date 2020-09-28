import logging
import pyodbc

from dataclasses import dataclass, field
from typing import List, Type, cast

from dataclasses_json import LetterCase, dataclass_json  # type: ignore

from lisa import notifier, schema
from lisa.testsuite import TestResultMessage


@dataclass_json(letter_case=LetterCase.CAMEL)
@dataclass
class DataBaseSchema(schema.TypedSchema):
    log_level: str = logging.getLevelName(logging.DEBUG)
    driver: str = field(default="")
    server: str = field(default="")
    database: str = field(default="")
    username: str = field(default="")
    password: str = field(default="")
    tablename: str = field(default="")


class DataBase(notifier.Notifier):
    """
    It's a sample notifier, output subscribed message to database.
    """

    @classmethod
    def type_name(cls) -> str:
        return "database"

    @classmethod
    def type_schema(cls) -> Type[schema.TypedSchema]:
        return DataBaseSchema

    def _initialize(self) -> None:
        runbook = cast(DataBaseSchema, self._runbook)
        connection = pyodbc.connect(
            "DRIVER={"
            + runbook.driver
            + "};SERVER="
            + runbook.server
            + ";DATABASE="
            + runbook.database
            + ";UID="
            + runbook.username
            + ";PWD="
            + runbook.password
        )
        self._cursor = connection.cursor()

    def finalize(self) -> None:
        self._cursor.close()

    def insert_table(self, records: str) -> None:
        self._cursor.execute(
            "insert into %s () values () where id=%s"
            % (self._runbook.tablename, records)
        )
        self._cursor.commit()

    def update_table(self, records: str) -> None:
        pass

    def select_table(self, column: str, value: str) -> None:
        self._cursor.execute(
            "select * from %s where %s=%s" % (self._runbook.tablename, column, value)
        )
        for row in self._cursor:
            print(row)

    def _received_message(self, message: notifier.MessageBase) -> None:
        runbook = cast(DataBaseSchema, self._runbook)
        self.select_table("ID", "1")
        self._log.log(
            getattr(logging, runbook.log_level),
            f"received message [{message.type}]: {message}",
        )

    def _subscribed_message_type(self) -> List[Type[notifier.MessageBase]]:
        return [TestResultMessage]
