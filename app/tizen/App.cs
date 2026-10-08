// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

using Tizen.Flutter.Embedding;
using Tizen.System;

namespace Runner
{
    public class App : FlutterApplication
    {
        protected override void OnCreate()
        {
            base.OnCreate();

            GeneratedPluginRegistrant.RegisterPlugins(this);

            // Dart reports Tizen as Linux, so the app asks here: "isTizen" (always true from this side; a Linux desktop has
            // no handler and the call fails there) and "isTelevision" (the device profile).
            var platform = new MethodChannel("wiretune/platform");
            platform.SetMethodCallHandler(call =>
            {
                switch (call.Method)
                {
                    case "isTizen":
                        return true;
                    case "isTelevision":
                        return Information.TryGetValue("http://tizen.org/feature/profile", out string profile)
                            && profile == "tv";
                    default:
                        throw new MissingPluginException();
                }
            });
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }
}
