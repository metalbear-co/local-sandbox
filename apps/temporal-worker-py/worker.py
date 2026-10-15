# Python twin of apps/temporal-worker (same CheckoutWorkflow/ProcessOrder names,
# same env vars), for reproducing sdk-core behavior under a Temporal split.
#
# The Go SDK reads the workflow's task queue from the WorkflowExecutionStarted
# history event (the ORIGIN queue), so its default-scheduled activities are
# valid even when mirrord patches the worker onto a virtual queue. sdk-core
# (Python/TypeScript) uses the worker's CONFIGURED queue instead - the patched
# virtual name - so without the operator rewriting completion commands the
# server rejects them with BadScheduleActivityAttributes. This worker exists to
# exercise that sdk-core path; the Go worker cannot.

import asyncio
import os
from datetime import timedelta

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker


@activity.defn(name="ProcessOrder")
async def process_order(order_id: str) -> str:
    info = activity.info()
    print(
        f"[ACTIVITY] workflow_id={info.workflow_id} "
        f"activity_type={info.activity_type} order_id={order_id}",
        flush=True,
    )
    return f"processed:{order_id}"


@workflow.defn(name="CheckoutWorkflow")
class CheckoutWorkflow:
    @workflow.run
    async def run(self, order_id: str) -> str:
        # No explicit task_queue - the customer shape that triggers the bug.
        return await workflow.execute_activity(
            "ProcessOrder",
            order_id,
            start_to_close_timeout=timedelta(minutes=1),
        )


async def main() -> None:
    address = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
    namespace = os.environ.get("TEMPORAL_NAMESPACE", "temporal")
    task_queue = os.environ.get("TEMPORAL_TASK_QUEUE", "order-checkout")

    print(f"[WORKER] address={address} namespace={namespace} task_queue={task_queue}", flush=True)
    client = await Client.connect(address, namespace=namespace)
    worker = Worker(
        client,
        task_queue=task_queue,
        workflows=[CheckoutWorkflow],
        activities=[process_order],
    )
    print("[WORKER] Started Worker", flush=True)
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
