// CloudFront Functions (Viewer Request) — IP 차단
// Geo-block은 CloudFront 기본 geo_restriction(whitelist KR)이 담당
// blocklist 갱신: Lambda Preventer → UpdateFunction API 호출로 재배포

var BLOCKED_IPS = [];

function handler(event) {
    var clientIp = event.viewer.ip;

    if (BLOCKED_IPS.indexOf(clientIp) >= 0) {
        return {
            statusCode: 403,
            statusDescription: 'Forbidden',
            headers: {
                'x-blocked-by': { value: 'devsecops-ip-block' }
            }
        };
    }

    return event.request;
}
