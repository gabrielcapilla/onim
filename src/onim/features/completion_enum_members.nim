import std/[algorithm, tables]

import ./completion_candidates
import ./completion_context
import ./completion_models
import ./completion_object_fields
import ./definition_models
import ../index/types
import ../session/workspace
import ../session/workspace_models
import ../syntax/tokens

proc completeEnumMembers*(
    source: WorkspaceSnapshot,
    context: MemberContext,
    receiver: ObjectReceiverResolution,
): CompletionResult =
  if not receiver.resolved or receiver.provider == nil:
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  let objectOrdinal = int(receiver.objectOrdinal)
  if objectOrdinal < 0 or objectOrdinal >= receiver.provider.types.objects.len or
      not appendObjectFields(
        receiver.provider,
        receiver.provider.types.fields,
        receiver.provider.types.objects[objectOrdinal],
        identifierKey(context.prefix),
        if receiver.exportedOnly: fieldsExported else: fieldsAll,
        candidates,
        candidateByName,
      ) or candidates.len == 0:
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = context.replaceStart
  result.replaceEnd = context.replaceEnd
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item
