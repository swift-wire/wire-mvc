import HTTPTypes
import Wire
import WireMVC
import WireMVCLogging

// Request-logger extensibility — an app-side field joining the request logger's metadata map. It stands in for what a
// distributed-tracing integration does: contribute a field, edit nothing. `WireMVCLogging` neither knows
// nor names this, and `requestLogger`'s signature is untouched — the map is the extension point.
//
// One declaration does both jobs, which is the point of a String-valued map: `TenantKeys.tenant` is
// injectable on its own AND appears on every log line.
//
// Request-scoped, deliberately: a seed scope's multibindings aggregate from that scope's own contributors,
// so an app-scoped contribution would be silently dropped rather than rejected.

enum TenantKeys {
    static let tenant = BindingKey<String>()
    static let metadataKey = "tenant"
}

@Scoped(seed: HTTPRequest.self)
enum TenantLogFields {
    @Provides(TenantKeys.tenant)
    @Contributes(to: WireMVCLogMetadata.stringEntries, atKey: TenantKeys.metadataKey)
    static func tenant(request: HTTPRequest) -> String {
        request.headerFields[HTTPField.Name("x-tenant")!] ?? "public"
    }
}
