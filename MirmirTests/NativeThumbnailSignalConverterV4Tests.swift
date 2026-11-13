import AVFoundation
import CoreVideo
import CryptoKit
import XCTest
@testable import Mirmir

final class NativeThumbnailSignalConverterV4Tests: XCTestCase {
    // Pins come from the retained independent Fraction physical-grid/matrix oracle.
    private static let expectedHashes: [String: String] = [
        "31x19-31x19-709-video-left": "741f1e7dd5c7fcf11fba2992746ab73667adc2b0ab9ff8f2931fcfac4d72234f",
        "31x19-31x19-709-video-center": "816f426c0fc82fe9ceb042bd9739a99df55aded51c6acf562e444dd11ea73051",
        "31x19-31x19-709-video-top_left": "4bd65242732d48e639cb63729d3fb9314e1855a6c7a9c6a1c67c5a59195d423c",
        "31x19-31x19-709-video-top": "b58b313711ef620fab4c685b26bec23a99c2fad42ac04d685c8087d01ad3851e",
        "31x19-31x19-709-video-bottom_left": "fc8ee416a569b0f9f3be5b4175f116c6f341ab1439152dae1995e2fcb438973f",
        "31x19-31x19-709-video-bottom": "4a34f7c2bfaefa55d3a5af55312f8091fd8422ee4f338dac3e82fc5f2ec57319",
        "31x19-31x19-601-video-left": "5e4d8c83d0e3c77988583351adb0067f1e8a1573d0ef67ffe3bd5b50ebad357f",
        "31x19-31x19-601-video-center": "b712588a068e6fcab08a4177bd60419a189bf1a42dfdb53b58e6da245906ce5e",
        "31x19-31x19-601-video-top_left": "50e61650db3258ae693b1c90effe3a6f969e9e2e451a88421bfe2c4c5d096a48",
        "31x19-31x19-601-video-top": "2bf18ac069aa8e4478a5e4b9daa703e9a94d047058becb326ff3e0e723b570a7",
        "31x19-31x19-601-video-bottom_left": "dc5514d7c27f9ba7ef6f34bf5aa5b24f0928d5ee0c45154bbd94c79447c62106",
        "31x19-31x19-601-video-bottom": "93564be539b50652f95ec1d006e4ae7ecc2e6f1bea2c616a796c320bcb279c90",
        "31x19-31x19-709-full-left": "c57b28db3f26f9a5ace76fc6bb0793808a0ff859749d961c9919fd21234ef40f",
        "31x19-31x19-709-full-center": "d44a2290b5dc6c7c1df2414eaec8071eef0d5288ca5c0b224049aee71b68c866",
        "31x19-31x19-709-full-top_left": "71184e17371ed67419cb3d099c545885edb22e8c6fc0e0a376433109592ef55d",
        "31x19-31x19-709-full-top": "273402cc1d65c2a95818be2f00f21e780daf37231b81f6f2d45540747c7c4293",
        "31x19-31x19-709-full-bottom_left": "1b34ed8e57dcbc1379c57231ffe9b4582865ea789ac0d7a71bcf944e2b676790",
        "31x19-31x19-709-full-bottom": "dab8c6699c0b3e239874ce1f6fe8bcbbca5ff4ee4e42961906dabd223b92c2d0",
        "31x19-31x19-601-full-left": "6a2a2cbe7e27e4fcbe235186f937527ac2bc474aa9c1696663b665f5624acbd3",
        "31x19-31x19-601-full-center": "2573f15a28621cd3af60d1f0d7294b427cd11567ea692c04cca85c6ddc39e35d",
        "31x19-31x19-601-full-top_left": "551ba82b1f8dc0bc93c3892326b228c702abafa2d125b6e6ea2bb95cf278a577",
        "31x19-31x19-601-full-top": "8674b959aca560d11457a9c77736eaf19455cf75afde2624b23da8b5f73138b4",
        "31x19-31x19-601-full-bottom_left": "55d8fcd1b88860e17c1b0050853bc62d45312143f44a7fb5322b9c052ac962e4",
        "31x19-31x19-601-full-bottom": "d9ff481c7390f349d32e5d7ac7edf233c36d25fd9e496ac70f5e3b4e2c54852d",
        "31x19-17x11-709-video-left": "7acc7be78d212002a83bf0d59d8cc090fa8dd37fe0ab92578f666a1742aed55b",
        "31x19-17x11-709-video-center": "a8a60237b846aa66e392d1fd9751356b284d19db450844aefe7f3feaddaaa05c",
        "31x19-17x11-709-video-top_left": "10178e45a4f608a27c8f813f6055a62c8a42328d16f512d5a24521185de1d4cf",
        "31x19-17x11-709-video-top": "c3bdbf228346482ab59563bdb187d94acc2611fffacbb7e533b8b9eda5c736bd",
        "31x19-17x11-709-video-bottom_left": "136c10f1f22c9c04ae09b86ce8df2f1c072d319a5a3fed33593f1e2a7594a2d6",
        "31x19-17x11-709-video-bottom": "d6d61cd9508c066f225ed092d783a3ab46335c3a29757901e99715b76ac1f65e",
        "31x19-17x11-601-video-left": "44677af4c48a0d5b3318e1e0db2c7c063f190e479efa28feda6915c8f51f3316",
        "31x19-17x11-601-video-center": "912217e0197c124a54d746a4c76849e5a7d7fb12edd6d4e5afabc8c444a6dc7e",
        "31x19-17x11-601-video-top_left": "7c03f14e4ac3ed814ec48a30aa43c6aa49bd3c13f3cb73ef0ac38dbe290ff621",
        "31x19-17x11-601-video-top": "3b83c5c64fb3126a698432852a29b9fb8c9a8bbbd01d2e5d8c2c65b87f1627dd",
        "31x19-17x11-601-video-bottom_left": "f2203d4a44049fea33a8f135a053aad8b9fda55ea0011427635c5de38d8f5325",
        "31x19-17x11-601-video-bottom": "cc1c4735cbce17a2508cd730c80d7e60cf3ba50bd0a4a68c655451c7aaff3325",
        "31x19-17x11-709-full-left": "56bb2579014fb938fd7d06fc05efaaa3172fbeb43b0511f37437537c1ec30a5b",
        "31x19-17x11-709-full-center": "84d520ccaa93e8543706d3b12280b1bd5defc27c348c69fc11f7e9155564353a",
        "31x19-17x11-709-full-top_left": "6c7279b44cfb44a229d796218536ef114ac28995aebb4c96fd89a14130bbee3e",
        "31x19-17x11-709-full-top": "ae770cacb49113513ed0088b533634028e19daed6f8950aa21e7bb47ffcc5bbc",
        "31x19-17x11-709-full-bottom_left": "c89014e2a80efb9444f2b0c86c6421cf6a73a9afa0f3909e284adf83f59256e5",
        "31x19-17x11-709-full-bottom": "5119e9f92954819b77244576057522ba9cb05f8fc38e7a5202c021d22af15734",
        "31x19-17x11-601-full-left": "ec12834743543625419bbb731a8032809d8e7598da8771e429deb22d15581678",
        "31x19-17x11-601-full-center": "caff8ef80561a0cb63855896c02405eb466a3b8d245ae99b555386cd9b476d08",
        "31x19-17x11-601-full-top_left": "b1cde49401821eeda5c269eef86baad6900f67e79d15d10cc749284bd15d9e0d",
        "31x19-17x11-601-full-top": "823141714707b0d4a56663f90cb964888b59d899602ffadc93a82981576799c9",
        "31x19-17x11-601-full-bottom_left": "a54f37a81794aaea2b9f175b7724d5104f89da31b0f326437818cdf4aad9be95",
        "31x19-17x11-601-full-bottom": "0a2c35404ef529ca96778c830ae0443aafeb2d4bf3bebe336a8f2b4e261f9a56",
        "31x19-1x1-709-video-left": "a1c82014107defb3ea871d72996af74fb45827a6443b2e06cbba1d0fae3f5679",
        "31x19-1x1-709-video-center": "43899dc0ac200c4c60b931cf2e557e72b30cf9103c7d94879dbdf0ffc4168fa7",
        "31x19-1x1-709-video-top_left": "8cfbd54275c87aa9e0d7b2e1c445c83729dcbf0c1218b7465e731a9757e7aa6b",
        "31x19-1x1-709-video-top": "41436e847089549d13176b125e034df4587cb396752bbe2787e74eb51e7c1250",
        "31x19-1x1-709-video-bottom_left": "41436e847089549d13176b125e034df4587cb396752bbe2787e74eb51e7c1250",
        "31x19-1x1-709-video-bottom": "39f90690c7c9021abdf994c130a1e8085e6f58291b7efa8388705b7212f38c4e",
        "31x19-1x1-601-video-left": "3b12081719f76164f333d399262533702849c765f4b1715a34aedf607737323e",
        "31x19-1x1-601-video-center": "ba659f5309a357afb59d35d1584db5ceef53731b78c8841276633b6599ce14b3",
        "31x19-1x1-601-video-top_left": "ff66e589f7d18c70e58b9bc34da1fd0ce5ed13f04a7b407e3a724c27efa7c2a3",
        "31x19-1x1-601-video-top": "dc4abb073156d59e14710442ca47902bd9e121badb148e148ddb1c306bcd4d4e",
        "31x19-1x1-601-video-bottom_left": "82410da352ea7f1af5ad0665072ad2f31dbb77926684c80618f398d09b3cbede",
        "31x19-1x1-601-video-bottom": "fc9cc53543334fbc00564c4f2a1af6428753ef61c0600260f22de3cd6bd4aa29",
        "31x19-1x1-709-full-left": "b07f6ae44cd1e894e9f72c23fb295e7d6a5cd210e64975bf3b612cdbdb7ee2ea",
        "31x19-1x1-709-full-center": "463e13845545f29fbef2700f4a7fdc5052da7490c20ae41fb7a08ea768b9e630",
        "31x19-1x1-709-full-top_left": "70b785c3da6c2b5dabb76fe5fbc232a9fd665ef818a191652eaae8f172e4187d",
        "31x19-1x1-709-full-top": "f0b2eb1f873e4fdbec948ccc546851702b20e167402177ec1d8a8c170fd665f0",
        "31x19-1x1-709-full-bottom_left": "31be0fe1a95c9abee15be9f3512239524deea637dda7f3b1f0cda42332f5a5f2",
        "31x19-1x1-709-full-bottom": "1a877d657af344ab40dc520d970a707ce5ae11fa3dbc2e29ef2521965947d1d0",
        "31x19-1x1-601-full-left": "8ebc4571c303fc136da7cdb6b159cc4ba3c0abd8a504d187c355d4d84e369997",
        "31x19-1x1-601-full-center": "61656fb230e357ef0eafd57de7e991f935356b268bbfd60f9287a3677e5719ff",
        "31x19-1x1-601-full-top_left": "196c8bd3a19323ce72eb066e5303b4e26c924bd305b8b15cb5dcd9386928cebd",
        "31x19-1x1-601-full-top": "d55df888e3193361fa5ae72b77b5c3a428c3d2442540f8fcdec94d96bde77bba",
        "31x19-1x1-601-full-bottom_left": "1c25aec5635d21783370107693a7e0b158b932d2bc30c911e35583651c5e29b5",
        "31x19-1x1-601-full-bottom": "ef6f80b19ff9aad43c9182432feafa21a446d3b86f89a8a256495f0f08f4522f",
        "128x96-64x48-709-video-left": "a6b69c2d33f58f86b926f9a51a1ed5cb4d00e1e87828a4c95a15f174ba923084",
        "128x96-64x48-709-video-center": "93c94d29a3d6007a7c443765f0f533e6255a3d1edd3f5f71638afd917216fd12",
        "128x96-64x48-709-video-top_left": "57670e2bb5dec08eaa9c341e8ce8285d13f7a293813befb83f74b1b02ae2c39f",
        "128x96-64x48-709-video-top": "285e260e2d4b8ef8b41ef6f604be9c57ab411dbc51088c6f7c164629d61be4b0",
        "128x96-64x48-709-video-bottom_left": "8f37603da8f4ad8409a165c7b505f473efbaffd68ca65aeb026cbcadd7fc487c",
        "128x96-64x48-709-video-bottom": "539f42e5e1941ffa431bb407cda24bee91020c2ad6e92020de15ed14627dd4e7",
        "128x96-64x48-601-video-left": "117a7c12c62e257b4cbc77e1458a0a79be299af49c276231ca413e43726842a4",
        "128x96-64x48-601-video-center": "c468d5605efaa927857616116c02a74981c6d81d92e7760c6ab037c164ff347f",
        "128x96-64x48-601-video-top_left": "ebe647c62e313dc2382f712737d985f7f7f4609782a3bd2cca021bc60111887f",
        "128x96-64x48-601-video-top": "aaea34bdd3616cf9ee6b554f8f8d2466be571c62c76403ae85ec27952b577502",
        "128x96-64x48-601-video-bottom_left": "d9fdc42a3a66d90619730df0b97abe0a914430cfd9374478684950756dee407e",
        "128x96-64x48-601-video-bottom": "7df6143be3893d867bbeb8bc840737eb84c70a15670cfb03dfdb9e5bbc1ceff8",
        "128x96-64x48-709-full-left": "9c7ded8d90fabf2ca897de419e5210049535d93d4a90f8957dcf7f3fa3042f03",
        "128x96-64x48-709-full-center": "4dcd3dad76a238c2df0993e8d62b65e5f37047bfbfe16844afacb6ccf006bd1a",
        "128x96-64x48-709-full-top_left": "f0711f52c8bcd7c7bb30f54f0a50e8dd8d9d5a848224eaccc1a5fe6ac193da7e",
        "128x96-64x48-709-full-top": "40759db36c2ebdcb1ccc49d8a0b703160a100de9a2dccb6e45b9216af26f53d9",
        "128x96-64x48-709-full-bottom_left": "e86a9b635cadfeb84903fa0fef27ca9cfb4c92d4629304a7f84c8502bf53b090",
        "128x96-64x48-709-full-bottom": "7255d8c5dd901b3c98bd2cd2b6abeaa2a6711398c4abc59c816863ae27077a52",
        "128x96-64x48-601-full-left": "7a58e3aa5532460ad37fe3312480ffdd52b9c71f939c3a1e01901413e634e96d",
        "128x96-64x48-601-full-center": "2f00593b43c521bef87747ee2b9d2b2712748086d21eff56f70b641635f3ea14",
        "128x96-64x48-601-full-top_left": "212ec9835e241781f3cfb28a85aa19bc357aa7e0800d366aa081b6e696cdb400",
        "128x96-64x48-601-full-top": "ed63c4f46a6d983ab37caf4e9dba5704c5d62d1783dcfd48d46e703067e93e60",
        "128x96-64x48-601-full-bottom_left": "7eed8fe765b0b26d5dbae2d9379dea5d92af5916a0b1aa714b757bbff46bc345",
        "128x96-64x48-601-full-bottom": "f800e14f5bab3157fc3c1745cda86cf2ce1ef175c33ead7bab3862dcdffd982b",
        "320x180-160x90-709-video-left": "6c580b29b3e5fd85850fe8afabe89c5a12da6c5bb993cf4583714539878a4a5b",
        "320x180-160x90-709-video-center": "13bb8db1921f6025d3f534a5743354d67b290b7e0bc03c330d4ef19d6a74c89d",
        "320x180-160x90-709-video-top_left": "cbce704a940deeb00b790184a7c2998e21d1b9c773ce46c9b4a7fa5469fe7a88",
        "320x180-160x90-709-video-top": "ebdc60cf0bd923ff9836cd18bf5a7ab4c92de9136c56bff6b30d6fd3e46c7281",
        "320x180-160x90-709-video-bottom_left": "cad425886336a473aa646baa14e54ee8c7475b3fe68b794076e001e45c81e779",
        "320x180-160x90-709-video-bottom": "bfb75721fdd010e0223c3b28aecad745925412c09a84983f2569e09221ed17ba",
        "320x180-160x90-601-video-left": "e18720e032417980c025c10bcc977b249f4fe132a36587559d12ca5047b0df43",
        "320x180-160x90-601-video-center": "51b54ba085134173a293d67fae07a4b40e54351d0ca385f100b529b32f67e459",
        "320x180-160x90-601-video-top_left": "aa023871be05d8a583bcf69509d5398820024bf24cef07e8ddefe301cdecd91d",
        "320x180-160x90-601-video-top": "aecc1ffb6242bea707f6737d22d30ad1f75071d3294650f9bf406c3487b515da",
        "320x180-160x90-601-video-bottom_left": "7f41a2f50effaf70770b3f9d0bee3895363315bfc7928ffe05354880cdc00dbf",
        "320x180-160x90-601-video-bottom": "4ef580f08e3f6d461951fdaa39a49a7bcab60c5657886b084f7611f8f61cace2",
        "320x180-160x90-709-full-left": "acb48834885f61c7f7387a8da3d32bb78f68d94af88c6a5e5e089448c6b6b557",
        "320x180-160x90-709-full-center": "e231f262720a6e7807d7611dccf31e10f34d514d72c3f5fb7c5715a9321e6fce",
        "320x180-160x90-709-full-top_left": "48dc2911a6f2def713640f3e312c3b8200499bdf73ecf289112e097848a460a3",
        "320x180-160x90-709-full-top": "6f3757f6e3c42ce25e4966403d33b8523ab4cf0ec3734acce856c41b8beb9b6f",
        "320x180-160x90-709-full-bottom_left": "7d976fdd35a0f725e511162aed836d283a044f6d7eaf9432115a5e2b20b92438",
        "320x180-160x90-709-full-bottom": "0cdf682b915783a570f59369c8a2e744394788a35a9c9659eb9dfa4e4a0cd42f",
        "320x180-160x90-601-full-left": "339708f670c962d9bd79405598a48cc40ff0ac7cdd2309764aee251d4d946e51",
        "320x180-160x90-601-full-center": "48f31255e3484513fb215ef6a5dc650c3d19896ebf42f4d1bf9c39ae1369f87c",
        "320x180-160x90-601-full-top_left": "f9196822130efc35feadadc63bb2fba9c51846486d858a62e9f5177c1aa3bd1d",
        "320x180-160x90-601-full-top": "4695f5fe14924482766f83703271f968b76c4f762d6e5aed66360ade2244277d",
        "320x180-160x90-601-full-bottom_left": "0b35a2bb7580de44f354d11bedbe87d2afe403a87b42792d027defb95872faa1",
        "320x180-160x90-601-full-bottom": "ee50e9e704c81c36bd5e7911b06b0a475e90316173b378608e699215c09c2095",
    ]

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture(width: Int, height: Int, matrix: String, full: Bool)
        throws -> (CVPixelBuffer, String, String) {
        let primaries = (matrix == "709" ? kCVImageBufferColorPrimaries_ITU_R_709_2
            : kCVImageBufferColorPrimaries_SMPTE_C) as String
        let nativeMatrix = (matrix == "709" ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
            : kCVImageBufferYCbCrMatrix_ITU_R_601_4) as String
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, full
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
            primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            nativeMatrix as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey,
            1 as CFNumber, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height { for x in 0..<width {
            luma[y * ys + x] = UInt8((x * 13 + y * 17 + 29) % 256)
        }}
        for y in 0..<(height + 1) / 2 { for x in 0..<(width + 1) / 2 {
            chroma[y * cs + x * 2] = UInt8((x * 31 + y * 19 + 7) % 256)
            chroma[y * cs + x * 2 + 1] = UInt8((x * 47 + y * 23 + 11) % 256)
        }}
        return (buffer, primaries, nativeMatrix)
    }

    private func active(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                .assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                result.append(base.advanced(by: y * stride), count: width)
            }
        }
        return result
    }

    func testPhysicalSignalsAndBoundedResamplingMatchIndependentOracle() throws {
        var count = 0
        for (w, h, ow, oh) in [(31, 19, 31, 19), (31, 19, 17, 11),
            (31, 19, 1, 1), (128, 96, 64, 48), (320, 180, 160, 90)] {
            for full in [false, true] { for matrix in ["709", "601"] {
                let (buffer, primaries, nativeMatrix) = try fixture(
                    width: w, height: h, matrix: matrix, full: full)
                for site in [CanonicalChromaSitingV4.left, .center, .topLeft,
                    .top, .bottomLeft, .bottom] {
                    let key = "\(w)x\(h)-\(ow)x\(oh)-\(matrix)-\(full ? "full" : "video")-\(site.rawValue)"
                    let before = try active(buffer)
                    let attachments = try XCTUnwrap(CVBufferCopyAttachments(buffer, .shouldPropagate))
                    let expectedSpace = try XCTUnwrap(
                        CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue())
                    let image = try NativeThumbnailSignalConverterV4.image(buffer: buffer,
                        contract: .init(width: w, height: h, siting: site, fullRange: full,
                            primaries: primaries,
                            transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                            matrix: nativeMatrix), size: CGSize(width: ow, height: oh))
                    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
                    XCTAssertEqual(hash(bytes), Self.expectedHashes[key], key)
                    XCTAssertEqual(image.colorSpace?.copyICCData(), expectedSpace.copyICCData(), key)
                    XCTAssertEqual(try active(buffer), before, key)
                    XCTAssertEqual(CVBufferCopyAttachments(buffer, .shouldPropagate), attachments, key)
                    XCTAssertEqual(bytes.count, ow * oh * 4)
                    count += 1
                }
            }}
        }
        XCTAssertEqual(count, Self.expectedHashes.count)
    }

    func testRejectsInvalidSizeAndDecodedSignalContradictions() throws {
        let (buffer, primaries, matrix) = try fixture(width: 31, height: 19, matrix: "709", full: false)
        let contract = NativeThumbnailSignalConverterV4.Contract(width: 31, height: 19,
            siting: .center, fullRange: false, primaries: primaries,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String, matrix: matrix)
        let original = try active(buffer)
        for size in [CGSize(width: 0, height: 1), CGSize(width: -1, height: 1),
            CGSize(width: 1601, height: 1), CGSize(width: 1, height: 1001),
            CGSize(width: 1.5, height: 1), CGSize(width: Double.nan, height: 1),
            CGSize(width: 1, height: Double.infinity)] {
            XCTAssertThrowsError(try NativeThumbnailSignalConverterV4.image(
                buffer: buffer, contract: contract, size: size))
            XCTAssertEqual(try active(buffer), original)
        }
        for (key, value) in [(kCVImageBufferFieldCountKey, 2 as CFNumber),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
            (kCVImageBufferMasteringDisplayColorVolumeKey, Data(repeating: 0, count: 24) as CFData)] as [(CFString, CFTypeRef)] {
            let saved = CVBufferCopyAttachment(buffer, key, nil)
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            XCTAssertThrowsError(try NativeThumbnailSignalConverterV4.image(buffer: buffer,
                contract: contract, size: CGSize(width: 31, height: 19)))
            XCTAssertEqual(try active(buffer), original)
            if let saved { CVBufferSetAttachment(buffer, key, saved, .shouldPropagate) }
            else { CVBufferRemoveAttachment(buffer, key) }
        }
    }

    func testEncodedContractRejectsGeometryDepthHDRAndFieldContradictions() async throws {
        let fixtures = try TemporaryFixtureDirectory()
        defer { fixtures.remove() }
        let url = fixtures.url(for: "native-thumbnail.mov")
        try await VideoProbeFixtureFactory.makeVideo(at: url, transform: .identity)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let descriptions = try await track.load(.formatDescriptions)
        let base = try XCTUnwrap(descriptions.first)
        XCTAssertNotNil(try NativeThumbnailSignalConverterV4.contract(descriptions: descriptions,
            transform: .identity, characteristics: []))
        XCTAssertNil(try NativeThumbnailSignalConverterV4.contract(descriptions: descriptions,
            transform: CGAffineTransform(rotationAngle: .pi / 2), characteristics: []))
        for characteristic in [AVMediaCharacteristic.containsAlphaChannel, .containsHDRVideo] {
            XCTAssertNil(try NativeThumbnailSignalConverterV4.contract(descriptions: descriptions,
                transform: .identity, characteristics: [characteristic]))
        }
        let original = try XCTUnwrap(CMFormatDescriptionGetExtensions(base)) as NSDictionary
        for (key, value) in [(kCMFormatDescriptionExtension_BitsPerComponent, 10 as CFNumber),
            (kCMFormatDescriptionExtension_FieldCount, 2 as CFNumber),
            (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCMFormatDescriptionExtension_MasteringDisplayColorVolume, Data(repeating: 0, count: 24) as CFData),
            (kCMFormatDescriptionExtension_PixelAspectRatio, [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: 2,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: 1] as CFDictionary)] as [(CFString, CFTypeRef)] {
            let changed = original.mutableCopy() as! NSMutableDictionary
            changed[key] = value
            var description: CMVideoFormatDescription?
            let dimensions = CMVideoFormatDescriptionGetDimensions(base)
            XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil,
                codecType: CMFormatDescriptionGetMediaSubType(base),
                width: dimensions.width, height: dimensions.height,
                extensions: changed, formatDescriptionOut: &description), noErr)
            XCTAssertNil(try NativeThumbnailSignalConverterV4.contract(
                descriptions: [try XCTUnwrap(description)], transform: .identity,
                characteristics: []), key as String)
        }
    }
}
