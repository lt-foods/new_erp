"use client";

import { Modal } from "@/components/Modal";
import FreeTransferCreateForm from "@/components/FreeTransferCreateForm";

export default function FreeTransferCreateModal({
  open,
  onClose,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (transferId: number) => void;
}) {
  return (
    <Modal open={open} onClose={onClose} title="🔄 建立自由轉貨" maxWidth="max-w-4xl">
      <FreeTransferCreateForm onCreated={onCreated} onCancel={onClose} />
    </Modal>
  );
}
