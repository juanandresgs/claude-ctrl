function reconcileBridgeSnapshot(snapshot, options = {}) {
  if (!snapshot || typeof snapshot !== 'object') {
    return snapshot;
  }

  const interactionGate = options.interactionGate ?? null;
  if (
    interactionGate?.status === 'open'
    && snapshot.state !== 'waiting_for_codex'
  ) {
    const advisories = [...(snapshot.advisories ?? [])];
    advisories.push(
      `Worker blocked on interaction gate (${interactionGate.gate_type}) in ${interactionGate.tmux_target}.`,
    );
    return {
      ...snapshot,
      state: 'interaction_gate',
      control_mode: 'review',
      instruction_id: interactionGate.instruction_id ?? snapshot.instruction_id ?? null,
      interaction_gate: interactionGate,
      jeff_state: 'Needs Attention',
      advisories,
    };
  }

  const inflightInstructionId = snapshot.inflight?.instruction_id ?? null;
  if (!inflightInstructionId) {
    return snapshot;
  }

  if (snapshot.state === 'waiting_for_codex') {
    return snapshot;
  }

  return {
    ...snapshot,
    state: 'inflight',
    instruction_id: inflightInstructionId,
  };
}

export { reconcileBridgeSnapshot };
