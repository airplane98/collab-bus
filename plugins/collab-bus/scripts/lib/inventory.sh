#!/usr/bin/env bash
# collab-bus vendored inventory — THE single machine-readable list of what a project's
# collab/bin/ must contain. SOURCE this file; it defines variables and nothing else.
#
# It exists because the same fact was written twice: bootstrap had a VENDOR array of what
# it copies, preflight had its own list of what it requires, and a test tried to keep them
# aligned by grepping one file for names mentioned in the other — which a COMMENT could
# satisfy. Two lists of one fact diverge, and the divergence shows up as "complete by the
# writer, incomplete by the checker" (or worse, the reverse). One list, two readers.
#
# Adding a script here is all that is needed for bootstrap to vendor it and preflight to
# demand it.
COLLAB_BINS="next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh participant.sh route.sh preflight.sh"
COLLAB_LIBS="lib/envelope.sh lib/manifest.sh lib/inventory.sh"
