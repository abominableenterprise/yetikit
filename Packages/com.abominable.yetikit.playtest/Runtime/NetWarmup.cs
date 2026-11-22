using System;
using System.Threading;
using System.Threading.Tasks;

namespace YetiKit.Playtest
{
    public static class NetWarmup
    {
        /// <summary>Optional anonymous startup ping; no retries or diagnostics.</summary>
        public static async Task<bool> PingAsync(IUploadSettings settings, IHttpSender sender, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!UploadValidation.TryGetEndpoint(settings, out var endpoint, requireKey: false)) return false;
            try
            {
                var response = await sender.SendAsync(new HttpRequest("GET", endpoint + "/ping"), cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                return response.Success;
            }
            catch (Exception) { cancellationToken.ThrowIfCancellationRequested(); return false; }
        }
    }
}
