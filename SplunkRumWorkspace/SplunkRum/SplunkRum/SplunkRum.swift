/*
Copyright 2021 Splunk Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import ZipkinExporter
import StdoutExporter

/**
 Optional configuration for SplunkRum.initialize()
 */
@objc public class SplunkRumOptions: NSObject {

    /**
        Default options
     */
    @objc public override init() {
    }

    /**
        Memberwise initializer
     */
    @objc public init(allowInsecureBeacon: Bool = false, enableCrashReporting: Bool = true, debug: Bool = false, globalAttributes: [String: Any] = [:]) {
        self.allowInsecureBeacon = allowInsecureBeacon
        self.enableCrashReporting = enableCrashReporting
        self.debug = debug
        self.globalAttributes = globalAttributes
    }
    /**
        Copy constructor
     */
    @objc public init(opts: SplunkRumOptions) {
        self.allowInsecureBeacon = opts.allowInsecureBeacon
        self.enableCrashReporting = opts.enableCrashReporting
        self.debug = opts.debug
        // shallow copy of the map
        self.globalAttributes = [:].merging(opts.globalAttributes) { _, new in new }
    }

    /**
            Allows non-https beaconUrls.  Default: false
     */
    @objc public var allowInsecureBeacon: Bool = false
    /**
                    Turns on the crash reporting with PLCrashReporter feature.  Default: true
     */
    @objc public var enableCrashReporting: Bool = true
    /**
            Turns on debug logging (including printouts of all spans)  Default: false
     */
    @objc public var debug: Bool = false
    /**
                    Specifies additional attributes to add to every span.  Acceptable value types are Int, Double, String, and Bool.  Other value types will be silently ignored
     */
    @objc public var globalAttributes: [String: Any] = [:]
}
var globalAttributes: [String: Any] = [:]
let splunkLibraryLoadTime = Date()
var splunkRumInitializeCalledTime = Date()

/**
 Main class for initializing the SplunkRum agent.
 */
@objc public class SplunkRum: NSObject {
    static var initialized = false
    static var initializing = false
    static var configuredOptions: SplunkRumOptions?
    static var theBeaconUrl: String?
    static var limitingExporter: LimitingExporter?

    /**
            Initialization function.  Call as early as possible in your application, but only on the main thread.
                - Parameter beaconUrl: Destination for the captured data.
     
                - Parameter rumAuth: Publicly-visible `rumAuth` value.  Please do not paste any other access token or auth value into here, as this will be visible to every user of your app
                - Parameter options: Non-required configuration toggles for various features.  See SplunkRumOptions struct for details.
     
     */
    @objc public class func initialize(beaconUrl: String, rumAuth: String, options: SplunkRumOptions? = nil) {
        if !Thread.isMainThread {
            print("SplunkRum: Please call SplunkRum.initialize only on the main thread")
            return
        }
        if initialized || initializing {
            debug_log("SplunkRum already initializ{ed,ing}")
            return
        }
        splunkRumInitializeCalledTime = Date()
        initializing = true
        defer {
            initializing = false
        }
        debug_log("SplunkRum.initialize")
        if options != nil {
            configuredOptions = SplunkRumOptions(opts: options!)
        }
        if options?.globalAttributes != nil {
            setGlobalAttributes(options!.globalAttributes)
        }
        if !beaconUrl.starts(with: "https:") && options?.allowInsecureBeacon != true {
            print("SplunkRum: beaconUrl must be https or options: allowInsecureBeacon must be true")
            return
        }
        theBeaconUrl = beaconUrl
        let exportOptions = ZipkinTraceExporterOptions(endpoint: beaconUrl+"?auth="+rumAuth, serviceName: "myservice") // FIXME control zipkin better to not emit unneeded fields
        let zipkin = ZipkinTraceExporter(options: exportOptions)
        OpenTelemetrySDK.instance.tracerProvider.addSpanProcessor(GlobalAttributesProcessor())
        limitingExporter = LimitingExporter(proxy: zipkin)
        OpenTelemetrySDK.instance.tracerProvider.addSpanProcessor(BatchSpanProcessor(spanExporter: limitingExporter!))
        if options?.debug ?? false {
            OpenTelemetrySDK.instance.tracerProvider.addSpanProcessor(SimpleSpanProcessor(spanExporter: StdoutExporter(isDebug: true)))
        }
        sendAppStartSpan()
        let srInit = buildTracer()
            .spanBuilder(spanName: "SplunkRum.initialize")
            .setStartTime(time: splunkRumInitializeCalledTime)
            .startSpan()
        srInit.setAttribute(key: "component", value: "appstart")
        initalizeNetworkInstrumentation()
        initalizeUIInstrumentation()
        if options?.enableCrashReporting ?? true {
            initializeCrashReporting()
        }
        srInit.end()
        initialized = true
        print("SplunkRum.initialize() complete")
    }

    /**
            Query for the current session ID.  Session IDs can change during the usage of the app so caching this result is not advised.
     */
    @objc public class func getSessionId() -> String {
        return getRumSessionId()
    }

    /**
            Convenience function for reporting an error.
     */
    @objc public class func reportError(string: String) {
        reportStringErrorSpan(e: string)
    }
    /**
            Convenience function for reporting an error.
     */
    @objc public class func reportError(exception: NSException) {
        reportExceptionErrorSpan(e: exception)
    }
    /**
            Convenience function for reporting an error.
     */
    @objc public class func reportError(error: Error) {
        reportErrorErrorSpan(e: error)
    }

    /**
        Set or override  one or more global attributes; acceptable types are Int, Double, String, and Bool.  Other value types will be silently ignored.  Can only be called after SplunkRum.initialize()
     */
    @objc public class func setGlobalAttributes(_ attributes: [String: Any]) {
        globalAttributes.merge(attributes) { (_, new) in
            return new
        }
    }
    /**
            Remove the global attribute with the specified key
     */
    @objc public class func removeGlobalAttribute(_ key: String) {
        globalAttributes.removeValue(forKey: key)
    }

    /**
            Specifies a better screen.name value.  CAUTION - if you use this API, you must use it everywhere;
        specifying any screen name manually will cause our automatic name choice (based on ViewController type name) to never be used again. In other words, if you use this once, you need to think through all the places where you'd like the screen name to be changed.
     */
    @objc public class func setScreenName(_ name: String) {
        screenNameManuallySet = true
        screenName = name
    }

    /**
     Sets a filter that rejects (drops) spans.  The closure passed should return true if the span should be rejected (not sent / dropped) and false otherwise
     */
    public class func setSpanRejectionFilter(_ filter: @escaping (SpanData) -> Bool) {
        limitingExporter?.setRejectionFilter(filter)
    }

}
