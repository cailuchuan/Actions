import Foundation
import Alamofire

class BaiduTranslate {
    // ========= 在这里填入你的百度云密钥 =========
    static let API_KEY = "替换成你的API_KEY"
    static let SECRET_KEY = "替换成你的SECRET_KEY"
    // ==========================================
    static var accessToken:String?
    
    static func fetchToken(completion:@escaping(String?)->Void) {
        let url = "https://aip.baidubce.com/oauth/2.0/token"
        let params:[String:String] = [
            "grant_type":"client_credentials",
            "client_id":API_KEY,
            "client_secret":SECRET_KEY
        ]
        AF.request(url, method: .post, parameters: params).responseJSON { res in
            guard let json = res.value as? [String:Any],
                  let token = json["access_token"] as? String else {
                completion(nil)
                return
            }
            accessToken = token
            completion(token)
        }
    }
    
    static func speechRecognition(audioData:Data, completion:@escaping(String?)->Void) {
        guard let token = accessToken else {
            fetchToken{ t in
                if let t = t { speechRecognition(audioData:audioData, completion:completion) }
                else {completion(nil)}
            }
            return
        }
        let url = "https://vop.baidu.com/server_api"
        let params:[String:Any] = [
            "format":"pcm",
            "rate":16000,
            "dev_pid":10005, //日语识别
            "token":token,
            "cuid":"troll_ios_movie",
            "speech":audioData.base64EncodedString(),
            "len":audioData.count
        ]
        AF.request(url, method:.post, parameters:params, encoding:JSONEncoding.default)
        .responseJSON { res in
            guard let json = res.value as? [String:Any],
                  let resArr = json["result"] as? [String] else {
                completion(nil)
                return
            }
            let jaText = resArr.joined()
            translateJP2CN(text:jaText, token:token, completion:completion)
        }
    }
    
    static func translateJP2CN(text:String, token:String, completion:@escaping(String?)->Void) {
        let url = "https://aip.baidubce.com/rpc/2.0/mt/texttrans/v1?access_token=\(token)"
        let body:[String:Any] = ["from":"jp","to":"zh","q":text]
        AF.request(url, method:.post, parameters:body, encoding:JSONEncoding.default)
        .responseJSON { rsp in
            guard let json = rsp.value as? [String:Any],
                  let result = json["result"] as? [String:Any],
                  let transList = result["trans_result"] as? [[String:String]],
                  let cnText = transList.first?["dst"] else {
                completion(nil)
                return
            }
            completion(cnText)
        }
    }
}
