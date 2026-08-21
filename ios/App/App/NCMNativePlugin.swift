import Capacitor
import Foundation
import NeteaseCloudMusicAPI

/// 网易云 API 原生桥接插件
///
/// 渲染进程是 WKWebView 里的 JS，无法直接调用 Swift；而 `capacitor://localhost` 源下
/// 没有可承载 `/api/netease` 的服务。因此 iOS 端把 axios 的传输层换成本插件，
/// 由 NeteaseCloudMusicAPI-Swift 以直连模式（本地 WeAPI/EAPI 加密）请求网易云。
///
/// JS 侧对接见 `src/utils/nativeRequest.ts`。
@objc(NCMNativePlugin)
public class NCMNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NCMNativePlugin"
    public let jsName = "NCMNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "request", returnType: CAPPluginReturnPromise)
    ]

    /// 直连模式客户端：不传 serverUrl 即由 SDK 本地加密后直接请求网易云，无需任何后端
    private let client = NCMClient()

    /// 已下发给 SDK 的 Cookie，避免每个请求都重复解析
    private var appliedCookie: String?

    // MARK: - 桥接入口

    @objc func request(_ call: CAPPluginCall) {
        guard let route = call.getString("route"), !route.isEmpty else {
            call.reject("缺少 route 参数")
            return
        }
        let params = call.getObject("params") ?? [:]

        // 登录态由渲染进程维护（document.cookie + localStorage），每次请求下发
        if let cookie = call.getString("cookie"), !cookie.isEmpty, cookie != appliedCookie {
            client.setCookie(cookie)
            appliedCookie = cookie
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.dispatch(route: route, params: params)
                let body = self.shapeBody(route: route, response: response, params: params)
                // keys 用于判断响应结构是否符合前端预期；cookies 数量用于排查登录态问题
                CAPLog.print(
                    "[NCMNative] ✅ \(route) status=\(response.status) "
                        + "cookies=\(response.cookies.count) keys=\(body.keys.sorted())"
                )
                call.resolve([
                    "status": response.status,
                    "body": body,
                ])
            } catch let error as RouteError {
                CAPLog.print("[NCMNative] ❌ \(route) 未接入")
                call.reject(error.description, "ROUTE_UNSUPPORTED")
            } catch let error as ParamError {
                CAPLog.print("[NCMNative] ❌ \(route) 参数错误：\(error.description)")
                call.reject(error.description, "PARAM_INVALID")
            } catch {
                CAPLog.print("[NCMNative] ❌ \(route) 请求失败：\(error.localizedDescription)")
                call.reject(error.localizedDescription, "NATIVE_REQUEST_FAILED")
            }
        }
    }

    // MARK: - 响应结构兼容

    /// 把 SDK 返回的原始网易云 body 调整成 Node 后端的形状
    ///
    /// 渲染进程是照着 Node 版 `NeteaseCloudMusicApi` 的响应写的，而其中 11 个模块
    /// **不是直接透传** —— 它们会把原始响应重新包装。SDK 返回的是原始 body，
    /// 因此这些路由必须在此补齐包装，否则前端取不到字段。
    ///
    /// 判定这 11 个时踩过一次坑：最初只匹配 `return { ... body: ... }`，
    /// 漏掉了 `result = { ... }` 后再 `return result` 的写法（如 login_status.js），
    /// 导致启动时的登录校验一直失败。正确的判定是「构造了含 `body: {` 的对象字面量」。
    private func shapeBody(route: String, response: APIResponse, params p: JSObject) -> [String: Any] {
        switch route {
        // 整个 body 被包进 data
        case "/login/qr/key", "/song/url":
            return ["code": 200, "data": response.body]

        // login_status.js：code == 200 时包成 { data: { ...body } }
        // 前端据此访问 loginState.data.profile（User.vue:172）；
        // 缺这层包装会走进「登录已过期」分支，把 userLoginStatus 置为 false
        case "/login/status":
            let code = response.body["code"] as? Int
            guard code == 200 else { return response.body }
            return ["data": response.body]

        // 登录类接口：Node 侧把响应头的 Set-Cookie 用 ';' 连接后塞进 body 的 cookie 字段
        // （login_qr_check / login_cellphone / login_refresh / login），
        // 而 Fastify 只 `reply.send(result.body)`，所以前端是从 body.cookie 取凭据的
        case "/login/qr/check", "/login/cellphone", "/login/refresh", "/login":
            var body = response.body
            body["cookie"] = response.cookies.joined(separator: ";")
            return body

        case "/song/url/v1":
            // Node 侧把结果重整为 data 数组；SDK 已返回 { code, data: [...] } 形状时直接用
            if response.body["data"] != nil { return response.body }
            return ["code": 200, "data": response.body]

        case "/scrobble":
            return ["code": 200, "data": "success", "details": response.body]

        default:
            return response.body
        }
    }

    // MARK: - 错误类型

    /// 尚未接入分发表的路由
    private struct RouteError: Error, CustomStringConvertible {
        let route: String
        var description: String { "iOS 端尚未接入该接口：\(route)" }
    }

    /// 必填参数缺失或无法解析
    private struct ParamError: Error, CustomStringConvertible {
        let key: String
        let type: String
        var description: String { "参数 \(key) 无法解析为 \(type)" }
    }

    // MARK: - 路由分发

    /// 把 Node 后端风格的路由分发到 SDK 的强类型方法
    ///
    /// 不能做成「路径透传」：SDK 的 typed 方法除了路由，还封装了每个接口的参数整形
    /// （如 songDetail 要把 ids 拼成 `c` 字段）、加密模式选择与后处理（如 songUrl 的
    /// autoUnblock），这些逻辑无法从 JS 侧复刻。RouteMap 的映射方向是
    /// 「NCM 路径 → Node 路由」，服务于后端代理模式，也不能反过来用。
    ///
    /// 本分发表由脚本从 `src/api/*.ts` 的实际调用与 SDK 的公开签名机械匹配生成，
    /// 覆盖 100 条路由。未列出的路由会抛 RouteError 显式失败，而非静默返回空数据。
    private func dispatch(route: String, params p: JSObject) async throws -> APIResponse {
        switch route {
        case "/aidj/content/rcmd":
            return try await client.aidjContentRcmd(
                latitude: double(p, "latitude"),
                longitude: double(p, "longitude")
            )

        case "/album":
            return try await client.album(
                id: int(p, "id") ?? 0
            )

        case "/album/detail/dynamic":
            return try await client.albumDetailDynamic(
                id: int(p, "id") ?? 0
            )

        case "/album/new":
            return try await client.albumNew(
                area: AlbumListArea(rawValue: string(p, "area") ?? "") ?? .all,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/album/sub":
            return try await client.albumSub(
                id: int(p, "id") ?? 0,
                action: try requireEnum(p, "t", SubAction.self)
            )

        case "/album/sublist":
            return try await client.albumSublist(
                limit: int(p, "limit") ?? 25,
                offset: int(p, "offset") ?? 0
            )

        case "/artist/album":
            return try await client.artistAlbum(
                id: int(p, "id") ?? 0,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/artist/detail":
            return try await client.artistDetail(
                id: int(p, "id") ?? 0
            )

        case "/artist/list":
            return try await client.artistList(
                area: ArtistArea(rawValue: string(p, "area") ?? "") ?? .all,
                type: ArtistType(rawValue: string(p, "type") ?? "") ?? .male,
                initial: string(p, "initial") ?? "",
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/artist/mv":
            return try await client.artistMv(
                id: int(p, "id") ?? 0,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/artist/songs":
            return try await client.artistSongs(
                id: int(p, "id") ?? 0,
                limit: int(p, "limit") ?? 50,
                offset: int(p, "offset") ?? 0,
                order: ArtistSongsOrder(rawValue: string(p, "order") ?? "") ?? .hot
            )

        case "/artist/sub":
            return try await client.artistSub(
                id: int(p, "id") ?? 0,
                action: try requireEnum(p, "action", SubAction.self)
            )

        case "/artist/sublist":
            return try await client.artistSublist(
                limit: int(p, "limit") ?? 25,
                offset: int(p, "offset") ?? 0
            )

        case "/artists":
            return try await client.artists(
                id: int(p, "id") ?? 0
            )

        case "/captcha/sent":
            return try await client.captchaSent(
                phone: string(p, "phone") ?? "",
                ctcode: string(p, "ctcode") ?? "86"
            )

        case "/captcha/verify":
            return try await client.captchaVerify(
                phone: string(p, "phone") ?? "",
                captcha: string(p, "captcha") ?? "",
                ctcode: string(p, "ctcode") ?? "86"
            )

        case "/cloud/import":
            return try await client.cloudImport(
                md5: string(p, "md5") ?? "",
                songId: int(p, "songId") ?? -2,
                bitrate: int(p, "bitrate") ?? 0,
                fileSize: int(p, "fileSize") ?? 0,
                song: string(p, "song") ?? "",
                artist: string(p, "artist") ?? "未知",
                album: string(p, "album") ?? "未知",
                fileType: string(p, "fileType") ?? "mp3"
            )

        case "/cloud/match":
            return try await client.cloudMatch(
                uid: int(p, "uid") ?? 0,
                sid: int(p, "sid") ?? 0,
                asid: int(p, "asid") ?? 0
            )

        case "/cloudsearch":
            return try await client.cloudsearch(
                keywords: string(p, "keywords") ?? "",
                type: SearchType(rawValue: int(p, "type") ?? -1) ?? .single,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/comment/hot":
            return try await client.commentHot(
                type: try requireEnum(p, "type", CommentType.self),
                id: int(p, "id") ?? 0,
                limit: int(p, "limit") ?? 20,
                offset: int(p, "offset") ?? 0,
                beforeTime: int(p, "beforeTime") ?? 0
            )

        case "/comment/hug/list":
            return try await client.commentHugList(
                uid: int(p, "uid") ?? 0,
                cid: int(p, "cid") ?? 0,
                sid: int(p, "sid") ?? 0,
                type: int(p, "type") ?? 0,
                cursor: string(p, "cursor") ?? "-1",
                page: int(p, "page") ?? 1,
                pageSize: int(p, "pageSize") ?? 100
            )

        case "/comment/new":
            return try await client.commentNew(
                type: try requireEnum(p, "type", CommentType.self),
                id: int(p, "id") ?? 0,
                pageNo: int(p, "pageNo") ?? 1,
                pageSize: int(p, "pageSize") ?? 20,
                sortType: int(p, "sortType") ?? 99,
                cursor: string(p, "cursor") ?? ""
            )

        case "/countries/code/list":
            return try await client.countriesCodeList()

        case "/daily_signin":
            return try await client.dailySignin(
                type: DailySigninType(rawValue: int(p, "type") ?? -1) ?? .android
            )

        case "/dj/category/recommend":
            return try await client.djCategoryRecommend()

        case "/dj/catelist":
            return try await client.djCatelist()

        case "/dj/detail":
            return try await client.djDetail(
                rid: int(p, "rid") ?? 0
            )

        case "/dj/personalize/recommend":
            return try await client.djPersonalizeRecommend(
                limit: int(p, "limit") ?? 6,
                offset: int(p, "offset") ?? 0
            )

        case "/dj/program":
            return try await client.djProgram(
                rid: int(p, "rid") ?? 0,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0,
                asc: bool(p, "asc") ?? false
            )

        case "/dj/program/detail":
            return try await client.djProgramDetail(
                id: int(p, "id") ?? 0
            )

        case "/dj/radio/hot":
            return try await client.djRadioHot(
                cateId: int(p, "cateId") ?? 0,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/dj/recommend":
            return try await client.djRecommend()

        case "/dj/recommend/type":
            return try await client.djRecommendType(
                cateId: int(p, "cateId") ?? 0
            )

        case "/dj/sub":
            return try await client.djSub(
                rid: int(p, "rid") ?? 0,
                action: try requireEnum(p, "action", SubAction.self)
            )

        case "/dj/sublist":
            return try await client.djSublist(
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/dj/toplist":
            return try await client.djToplist(
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0,
                type: int(p, "type") ?? 0
            )

        case "/fm_trash":
            return try await client.fmTrash(
                id: int(p, "id") ?? 0,
                alg: string(p, "alg") ?? "RT",
                time: int(p, "time") ?? 25
            )

        case "/hug/comment":
            return try await client.hugComment(
                uid: int(p, "uid") ?? 0,
                cid: int(p, "cid") ?? 0,
                sid: int(p, "sid") ?? 0,
                type: int(p, "type") ?? 0
            )

        case "/like":
            return try await client.like(
                id: int(p, "id") ?? 0,
                like: bool(p, "like") ?? true
            )

        case "/likelist":
            return try await client.likelist(
                uid: int(p, "uid") ?? 0
            )

        case "/login/cellphone":
            return try await client.loginCellphone(
                phone: string(p, "phone") ?? "",
                password: string(p, "password") ?? "",
                countrycode: string(p, "countrycode") ?? "86",
                captcha: string(p, "captcha")
            )

        case "/login/qr/check":
            return try await client.loginQrCheck(
                key: string(p, "key") ?? ""
            )

        case "/login/qr/create":
            return try await client.loginQrCreate(
                key: string(p, "key") ?? "",
                qrimg: bool(p, "qrimg") ?? true
            )

        case "/login/qr/key":
            return try await client.loginQrKey()

        case "/login/refresh":
            return try await client.loginRefresh()

        case "/login/status":
            return try await client.loginStatus()

        case "/logout":
            return try await client.logout()

        case "/lyric/new":
            return try await client.lyricNew(
                id: int(p, "id") ?? 0
            )

        case "/music/first/listen/info":
            return try await client.musicFirstListenInfo(
                id: int(p, "id") ?? 0
            )

        case "/mv/all":
            return try await client.mvAll(
                area: MvArea(rawValue: string(p, "area") ?? "") ?? .all,
                type: MvType(rawValue: string(p, "type") ?? "") ?? .all,
                order: MvOrder(rawValue: string(p, "order") ?? "") ?? .hot,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/mv/sublist":
            return try await client.mvSublist(
                limit: int(p, "limit") ?? 25,
                offset: int(p, "offset") ?? 0
            )

        case "/personal_fm":
            return try await client.personalFm()

        case "/playlist/create":
            return try await client.playlistCreate(
                name: string(p, "name") ?? "",
                privacy: int(p, "privacy") ?? 0,
                type: string(p, "type") ?? "NORMAL"
            )

        case "/playlist/delete":
            return try await client.playlistDelete(
                ids: intList(p, "ids")
            )

        case "/playlist/detail":
            return try await client.playlistDetail(
                id: int(p, "id") ?? 0,
                s: int(p, "s") ?? 8
            )

        case "/playlist/privacy":
            return try await client.playlistPrivacy(
                id: int(p, "id") ?? 0
            )

        case "/playlist/subscribe":
            return try await client.playlistSubscribe(
                id: int(p, "id") ?? 0,
                action: try requireEnum(p, "action", SubAction.self),
                checkToken: string(p, "checkToken")
            )

        case "/playlist/track/all":
            return try await client.playlistTrackAll(
                id: int(p, "id") ?? 0,
                limit: int(p, "limit") ?? 1000,
                offset: int(p, "offset") ?? 0
            )

        case "/playlist/tracks":
            return try await client.playlistTracks(
                op: string(p, "op") ?? "",
                pid: int(p, "pid") ?? 0,
                trackIds: intList(p, "trackIds")
            )

        case "/playlist/update":
            return try await client.playlistUpdate(
                id: int(p, "id") ?? 0,
                name: string(p, "name") ?? "",
                desc: string(p, "desc") ?? "",
                tags: string(p, "tags") ?? ""
            )

        case "/playmode/intelligence/list":
            return try await client.playmodeIntelligenceList(
                id: int(p, "id") ?? 0,
                pid: int(p, "pid") ?? 0,
                sid: int(p, "sid"),
                count: int(p, "count") ?? 1
            )

        case "/recommend/songs/dislike":
            return try await client.recommendSongsDislike(
                id: int(p, "id") ?? 0
            )

        case "/resource/like":
            return try await client.resourceLike(
                id: int(p, "id") ?? 0,
                type: try requireEnum(p, "type", ResourceType.self),
                like: bool(p, "like") ?? false
            )

        case "/scrobble":
            return try await client.scrobble(
                id: int(p, "id") ?? 0,
                sourceid: int(p, "sourceid") ?? 0,
                time: int(p, "time") ?? 0
            )

        case "/search/default":
            return try await client.searchDefault()

        case "/search/hot/detail":
            return try await client.searchHotDetail()

        case "/search/match":
            return try await client.searchMatch(
                title: string(p, "title") ?? "",
                artist: string(p, "artist") ?? "",
                album: string(p, "album") ?? "",
                duration: int(p, "duration") ?? 0,
                md5: string(p, "md5") ?? ""
            )

        case "/search/multimatch":
            return try await client.searchMultimatch(
                keywords: string(p, "keywords") ?? ""
            )

        case "/search/suggest":
            return try await client.searchSuggest(
                keywords: string(p, "keywords") ?? "",
                type: SearchSuggestType(rawValue: string(p, "type") ?? "") ?? .mobile
            )

        case "/sheet/list":
            return try await client.sheetList(
                id: int(p, "id") ?? 0,
                ab: string(p, "ab") ?? "b"
            )

        case "/sheet/preview":
            return try await client.sheetPreview(
                id: int(p, "id") ?? 0
            )

        case "/song/chorus":
            return try await client.songChorus(
                id: int(p, "id") ?? 0
            )

        case "/song/detail":
            return try await client.songDetail(
                ids: intList(p, "ids")
            )

        case "/song/download/url/v1":
            return try await client.songDownloadUrlV1(
                id: int(p, "id") ?? 0,
                level: SoundQualityType(rawValue: string(p, "level") ?? "") ?? .exhigh
            )

        case "/song/dynamic/cover":
            return try await client.songDynamicCover(
                id: int(p, "id") ?? 0
            )

        case "/song/music/detail":
            return try await client.songMusicDetail(
                id: int(p, "id") ?? 0
            )

        case "/song/order/update":
            return try await client.songOrderUpdate(
                pid: int(p, "pid") ?? 0,
                ids: string(p, "ids") ?? ""
            )

        case "/song/url":
            return try await client.songUrl(
                ids: intList(p, "ids", "id"),
                br: int(p, "br") ?? 999000
            )

        case "/song/url/v1":
            return try await client.songUrlV1(
                ids: intList(p, "ids", "id"),
                level: SoundQualityType(rawValue: string(p, "level") ?? "") ?? .exhigh
            )

        case "/song/wiki/summary":
            return try await client.songWikiSummary(
                id: int(p, "id") ?? 0
            )

        case "/top/artists":
            return try await client.topArtists(
                limit: int(p, "limit") ?? 50,
                offset: int(p, "offset") ?? 0
            )

        case "/top/song":
            return try await client.topSong(
                type: TopSongType(rawValue: int(p, "type") ?? -1) ?? .all
            )

        case "/ugc/artist/search":
            return try await client.ugcArtistSearch(
                keyword: string(p, "keyword") ?? "",
                limit: int(p, "limit") ?? 40,
                offset: int(p, "offset") ?? 0
            )

        case "/user/account":
            return try await client.userAccount()

        case "/user/cloud":
            return try await client.userCloud(
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/user/cloud/del":
            return try await client.userCloudDel(
                ids: intList(p, "ids", "id")
            )

        case "/user/detail":
            return try await client.userDetail(
                uid: int(p, "uid") ?? 0
            )

        case "/user/level":
            return try await client.userLevel()

        case "/user/playlist":
            return try await client.userPlaylist(
                uid: int(p, "uid") ?? 0,
                limit: int(p, "limit") ?? 30,
                offset: int(p, "offset") ?? 0
            )

        case "/user/subcount":
            return try await client.userSubcount()

        case "/mv/detail":
            return try await client.mvDetail(mvid: int(p, "mvid") ?? int(p, "id") ?? 0)

        case "/mv/detail/info":
            return try await client.mvDetailInfo(mvid: int(p, "mvid") ?? int(p, "id") ?? 0)

        case "/mv/url":
            return try await client.mvUrl(id: int(p, "id") ?? 0, r: int(p, "r") ?? 1080)

        case "/video/detail":
            return try await client.videoDetail(id: string(p, "id") ?? "")

        case "/video/detail/info":
            return try await client.videoDetailInfo(vid: string(p, "vid") ?? string(p, "id") ?? "")

        case "/video/url":
            return try await client.videoUrl(id: string(p, "id") ?? "", resolution: int(p, "resolution") ?? 1080)

        case "/playlist/catlist":
            return try await client.playlistCatlist()

        case "/playlist/highquality/tags":
            return try await client.playlistHighqualityTags()

        case "/recommend/songs":
            return try await client.recommendSongs()

        case "/recommend/resource":
            return try await client.recommendResource()
        // ↓ 以下路由在 src/api 中是先赋值给变量再用（如 rec.ts:34、playlist.ts:72、playlist.ts:164），
        //   最初的字面量扫描没抓到，由真机测试暴露后补入
        case "/lyric":
            return try await client.lyric(id: int(p, "id") ?? 0)

        case "/personalized":
            return try await client.personalized(limit: int(p, "limit") ?? 30)

        case "/personalized/newsong":
            return try await client.personalizedNewsong(limit: int(p, "limit") ?? 10)

        case "/personalized/mv":
            return try await client.personalizedMv()

        case "/personalized/djprogram":
            return try await client.personalizedDjprogram()

        case "/personalized/privatecontent":
            return try await client.personalizedPrivatecontent()

        case "/top/playlist":
            return try await client.topPlaylist(
                cat: string(p, "cat") ?? "全部",
                limit: int(p, "limit") ?? 50,
                offset: int(p, "offset") ?? 0
            )

        case "/top/playlist/highquality":
            return try await client.topPlaylistHighquality(
                cat: string(p, "cat") ?? "全部",
                limit: int(p, "limit") ?? 50,
                offset: int(p, "offset") ?? 0,
                lasttime: int(p, "before", "lasttime") ?? 0
            )

        // 注意大小写：SDK 同时存在 toplist()（排行榜列表）与 topList(id:)（歌单详情），
        // 早期的大小写不敏感匹配把 /toplist 错接到了后者
        case "/toplist":
            return try await client.toplist()

        case "/toplist/detail":
            return try await client.toplistDetail()

        case "/artist/top/song":
            return try await client.artistTopSong(id: int(p, "id") ?? 0)

        default:
            throw RouteError(route: route)
        }
    }

    // MARK: - 参数提取

    /// JS 侧的数字可能以 Int / Double / String 任一形式过桥，统一归一化
    private func int(_ p: JSObject, _ keys: String...) -> Int? {
        for key in keys {
            switch p[key] {
            case let value as Int: return value
            case let value as Double: return Int(value)
            case let value as String: return Int(value)
            default: continue
            }
        }
        return nil
    }

    private func double(_ p: JSObject, _ keys: String...) -> Double? {
        for key in keys {
            switch p[key] {
            case let value as Double: return value
            case let value as Int: return Double(value)
            case let value as String: return Double(value)
            default: continue
            }
        }
        return nil
    }

    private func string(_ p: JSObject, _ keys: String...) -> String? {
        for key in keys {
            if let value = p[key] as? String { return value }
            if let value = p[key] as? Int { return String(value) }
        }
        return nil
    }

    /// JS 侧的布尔可能是真布尔，也可能是 "true" / 1
    private func bool(_ p: JSObject, _ keys: String...) -> Bool? {
        for key in keys {
            switch p[key] {
            case let value as Bool: return value
            case let value as Int: return value != 0
            case let value as String: return value == "true" || value == "1"
            default: continue
            }
        }
        return nil
    }

    /// ID 列表在 src/api 里既可能是数组，也可能是 "1,2,3" 形式的字符串
    private func intList(_ p: JSObject, _ keys: String...) -> [Int] {
        for key in keys {
            if let array = p[key] as? [Any] {
                return array.compactMap {
                    if let value = $0 as? Int { return value }
                    if let value = $0 as? Double { return Int(value) }
                    if let value = $0 as? String { return Int(value) }
                    return nil
                }
            }
            if let joined = p[key] as? String {
                return joined.split(separator: ",").compactMap {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
            }
            if let single = p[key] as? Int { return [single] }
            if let single = p[key] as? Double { return [Int(single)] }
        }
        return []
    }

    /// 解析 SDK 中无默认值的必填枚举参数
    ///
    /// 这类参数解析失败必须抛错而不能回落到任意值 —— 例如 SubAction 若把
    /// 「取消收藏」静默变成「收藏」，会造成与用户意图相反的写操作
    private func requireEnum<T: RawRepresentable>(
        _ p: JSObject, _ key: String, _ type: T.Type
    ) throws -> T where T.RawValue == Int {
        guard let raw = int(p, key), let value = T(rawValue: raw) else {
            throw ParamError(key: key, type: String(describing: type))
        }
        return value
    }

    private func requireEnum<T: RawRepresentable>(
        _ p: JSObject, _ key: String, _ type: T.Type
    ) throws -> T where T.RawValue == String {
        guard let raw = string(p, key), let value = T(rawValue: raw) else {
            throw ParamError(key: key, type: String(describing: type))
        }
        return value
    }
}
