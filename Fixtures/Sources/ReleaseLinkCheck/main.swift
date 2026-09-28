// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// Links `ReleaseLinkGuards`, which is all it is for: the guards in that library fail at link time, in an
// optimised build, if WireMVC stops exporting a symbol they reach. Running it proves only that it linked.
import ReleaseLinkGuards

print("release link guards linked: \(DroppedBoxRefusal.self)")
