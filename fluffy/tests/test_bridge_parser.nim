# Nimbus - Fluffy
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/json,
  unittest2, stew/results,
  ../rpc/bridge_client
  

let validResponse = 
  """
    [
        "0xf90211a0fce2c4224ecaf51b69484308ea35568971b415218d7637d10f280e7677138e25a05022f349259d1c65ea252cc1d92cbd408642dfb3ae1cd683f06ce9a70b6cf906a09006bc304a486ed0ffe1464cc7c3d30a6c2e2ad68fac739c2d0705d64f462924a0b656d29eb22c930facd52cb8eb7b0d8555a957fc0921c121ead8fcb610c8ec9ca0f0a37daafaa3e11d2bc716bda5fa05d19051ed868562f2f95b533ad07a93922aa0b39178c732d92c088caafb3edf59b8c2386f51f9c0f0c2e6fd15ccd97370b212a0dd4c1127c8825a5d8e3ab8672dd924dbf8bc11c36d2fe8b1cff402fd1eef7293a08d38ad80852443b92b420d84ae60fc3a00e697c62a719de7a40ee82ae6cb38e4a09142b8354a0076b2e52a46813a4d45c46ed615d26c8c572fc314b7fb8c3fb01fa01e8c254927ac9b4bf215af1eb5cada70b3f482090d51ecd2b6d96d37b8eaa673a0cbfa5159bdcc0b01c8ef4f0a677a53a3d328f992906a2b655c054337174bdcdba0c7a8961f9ef3ea9204ee8ea3185bbd074efcca69263950bbea8ac4e80ece64caa0da1ad45521bb56ffcf8fca5e8608013cdeea432d7b1568713ad153a4fe320055a04615903adaff7e9eb3d40a0741317af48903bce60c01bf7c8400c75ab3651c21a044501873aa9131297b5c77f91d7a83ba845788b96b74d8c79edf0937964cc1d5a071eebceffcbcce68b6ad34111bdc8240d14d0de7eb167970ccb84fe2e4815bc480",
        "0xf90211a0bbba86270da1fbd2494b8422b9af95136d56ea41a9d832377348ad3d1984ee8ea0092e9d7e087e1af915cb3ff58541f70a566dd216603db8d68273537c8dfd4581a07d0d978774c613fe1952f997ff52f3fa660efef77ba05313744e71131d255a2ca01c034e63211f785b0b53f700e9d8861a3bc944336677544634945be33cb9378ca0333512e6b21cd35794bf53ec1f8f09803903bd2a9a0674be8ccfd563044275c9a0c1f240e6915bb06ffb9abad826d649e09ce1d7716895a274ec7d5b38f500b66fa0bec903e4d61bef1be9967d905a8bfd5120b532b81d10c3e52354a1f12592304ba0766f3b2c074dc2852dff6fd445638155546b483c5d7673471a772906dbc73784a019148d2973084180f8738eee2770526e5a85c3371df41e4404acd6a6cfa6592aa0a166be328bb46e1e2807c348a771a42f9296379af9c8da9e4a91c9d7a0067ceca0354f594ca3b5bc148d0d2206353a3ca87f089ba2ccb5378ee8407867d8729e84a02acd6b49c7eb7ee2754f7f93763eab704c88b108b9dba70e5c6536165f8e2ac3a0efde8ebfbfd5620a44ed084c419590a0c3851cf992c34a0aba8c8f3a51586befa08bbba2346f858f8d8db6ac71d56c5492dcb2d97794ef7c373df4060a6d43b96ba0843a5746bf11d7132a3aa1c923befe36a166ff1218d0724d8daa84311a15fc54a07a93c2c5a33cccf230060952c29071864c1a64d27a5c11789f998398e57bd0df80",
        "0xf90211a0bd0b284af4654ffcaed089a2ee9df7632eff089f5a5e8898183bec51ef0416f3a081d7c7dd28197e52c02449ecc48b8df8e1006bdf90b31b736ce008ac186d9804a0e3415ccdf6bac772ea647542e035d88cfee510b39f405f02077e36e7ce1eea90a0fd0b45678e1665e3082e7724ef54d214542c04eea8ec64a470344158cb5252f4a0d705052e6b2f9104dba913ca685410a4aac177f5f333061edabbf7b75afbfa1da09bae8a43d4c816a1a7cbd101efc71410412c8aa9b101c8901933a372df220df7a0c00e8e7b250202cf33fbe746e158df44001e8d3fc92fdb32420e318f622e2c14a08941d4fc06dfe97e38a91e0c0a99e4d6ea862544de4f16f410b5fe15bec4241ea0f686037a31e122f44eb4902855b0474997c7a594f7bacf7a29ad8f7b323362b3a0d0717e371b19f8cc8c568790537b706aff6497cdc927e74fb837e690537256baa090724a94d671c164d973b0a50bb96fd8adde9d8ab1135fbe30143d800ac355b6a04b420c2c4c113d47642dc3b4a96d9ed0c9865bc301a540280821a48a5b7f0f8ea0b99d35b3306f9b347d3d3a2815e929aba2d2ad9cc018acce03e740c2dfe85409a05f9c5e4e262249ae9f57b5797a4a5f55a18bfcece51f70b57b7d69865e5f9275a0487e275640a1079618a49262d84873c8bdafa9bb328a5982f766467209442570a0f14c0fdd9c045c5881b1d1a3852562e7cb56679b61eb45b3920ae609859dd2a880",
        "0xf90211a059473e1c514a41d49f43bb65df5896d52842d03b2bc69ce71a362d1aee97019ba0bacff9f2ff79983cf8a8bf56599b6a5a6de2a32be678a00ccf1055c1b0165fb0a0de837e80cfff3db9be85e02fffdc89509ea4ab645905672b2f0d4304d77eb9d1a00a21c4a02d45ad9b4c9640837d93fa1aff495993f720f71f1eb196a015b6f315a08acebcda44b77d40a8f56ddc12fc5e69473191d6abdcbf8436f3261dca3344b3a04c8faecbe77ba3ab47b7bcf8ab9d30f74c89bcb4473b6b94584fea474a883fe4a02b99825230ff879f07a1ab5866e379a22c24b7985c0c2018d4557e1917e2e996a04b30c444f8f1d223823ac1bb21a2d94e0119c9ab4561eb84b90018d270dc4511a072f8f6fcaed629fdfc6abf919e10cd78bb745959c9806cde12531f659be924aaa043abe0a4167a23deeab19acdd7dd67c5229774195860072deff16c5e0555013fa09341b0ab434b6f28ad14893cfd4f4232025520b49289e63727360304e93817caa02943f8b8273bdd48dbb88e69c28f254c23bf221d1cbe02aa0ded024922f826f3a07c081dfef46090404015b372f9ee557a0d4df2a2480e163fc5635cd4d8cc8ba0a0256364f00818d384cbec11ee3f65a9523691cf85443a0b4bf7ea29fba443f8c0a0704be56a170dd692ddaaf1104bf46369f544115deb3f035a0d0010adeea2de2ba0140b8558ca77050b9389a1b94f69a257dafb0841d4fa755655228bf7667bff9080",
        "0xf90211a0fb1fe5f63497f4ee1850b916611e073f36a179a2f63108226a577d4c6356a115a077b8747c09ba480fc5d7533967f14895927032096ac94fe04126616bf8ab7e60a0390e92ddbb1dd6b924da4dc074ea428fe49ef839d1f86695471e5461278a3d16a082aa9f0de62cb59ff57fe20f8548274ed02141ba0ac58cd2b85ed5952ae325a1a0c9adc496993df93f07ca376204a80c780bc818fd7ffdbd87f8548abcf4f94505a0dc0ff17b7fc9fd09781d9ad486fbde27d47347acbf73b3461a4d6a7a32d68d23a00ecf7125f1282ad1d5fb7bce5c9282c15f0e149a594d01c5b0c8dc5c1ce0f49aa050066a3d2073716754f2daaf7fc0e6b280bea4f83367fbaab6142d4d22e527b3a084453708f0cbfc04b0a9251553849141e08dd7b731f83dd6df1712fcb3a3e019a0e69707b4c8773c7fdabe6cadc1f232f5aa368a3792196635d4f88e91be25337aa06aef5bba742aa52808d37ef7a5793301529d6c55ff89352ed3dd6f245e1fe337a095a498f7a0059e07b57272f168f329b79a9eb84839a3c0a6fefb7c5a7fa2621da01b56fd545c72da546f8b1062f2a7a7032d767122fd67b00d30b2170387d83297a0f0c70f50108f257ba27f3c3a6bf7c5305a91caeb76cfaffd25f2b1ec30695a61a032979a9cb63c3fdd7733ba351c4bff451d7f0a62403ee811e2aff183358b899ba0e8f217c2d3d275ce101f92aae9dffb6cfc6d51e76bba7c0ddfd513c0223ef86c80",
        "0xf90211a014543399c40a324d32c0f1492619810c0e574c6777ac42ba1026edafc976befea0b9a1565358cc7acf3019f2a1e461be375d516c1e5b5cc5f89d98b6b5a50b4837a0cf9ec300720f7454b1f43e7fa66d5521f7c707bb3034a59e4132e4cc7d27464ea0b2b0079ce47aa23433bc9d18030f3f22953314f971eecd0663b1a4c6bdfd4971a09be239d7fe0fdefc410ea1132ec9c6fece89b5efd4762a04cae848c8bb7552dba05efaf993a5379ad5e2fb825a4b48f5db93be88365dd1c00e763b822b10cf9c8aa0839d8cb68a596a8caf4d1705423f08e5e649579783a16c74f7907e6651452edaa04d8550d004fefc2659c4ad6e7242b280bf48dddb5d0fbce13ae2160c07082c5ea058b683f7819a4879446d36c2972215679b3734ba859f3abad0eee2791b548a6ca0f48a4f2c6823f35f91718d6a96e4ae97ca6da5efdfa0c047520e586b03ac3d99a0ae8c3c088ed7d2b6cfc2eeae62a7bd00d1d608fbbf0af22b04dcd6358c278a45a0742e541865d9fc85437e8be8ce929a3a34078cdb43e70d5c1dd8da3e29453080a038d3660abbb76ef30b0f53af54ab076ddc77a0c91e1f14937f7dfff472f8f77ba09c9c591d5ef2ea4a0e3df9ff26bd6def0782cfd82ea15496545037a341d98a46a0fc31ff3c5e18689587ee3e3d47943e3343cdb1e9a355f6c594c0db68b79ec2cba06d2ef8329cf522ac8e1e3f60444a85f1fe8713c96c85f47d7c7dd8afe68e5b2180",
        "0xf8d1a0955dcc118bc73fbfccb7f5011602c2aa2b040017b8b9830be88e6120fc1d595e8080808080808080a055c84c8d70f9787cdc3cca63a55c1d6ca9bd1740a8b5154b3523cd32135ac24980a0c98ff789764ff3632af31fe9da517d74166a295512d2f228dfae5ecf883c844080a01f5631f585fda9bfdb82ba6a701d3ee6773f340bce8ef5baaf05b6b95b025aeca0a98d8d5806c182e36a2259a714dab678d3310991a264ad44f2a9cc054b1ae730a012692bf87c67d507301fc019f5952aa521eccdfb88a9dec6eabdc05fb2d61c3e80",
        "0xf87180a0d7d5b21d8cda17a270cd0ee93f1fef51822f1cd399cb04bf93f1345ea6fe4f6b80808080a0ed019018f85dfb624e9275ea63589170f1e8c5275e799d7e7ca23d0f56f4050180a023918853574f454b03ead293d77fe2e474678a1385901ee905f51650442fa6418080808080808080",
        "0xf8729d20a2bb59a483f7734179ef49f487685cfb857d92e96ab2afad3797212eb852f85083037e29890446423faf23dd8267a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        "0xf90211a0d2f69abd007bf23db66c29f488a9944e6873f0b553e0fa5dc208a8187ab45969a03235fdd70e844abd81c9d88e1521be7c6041933a5fbdd8862bca23a9612030baa0e50621f526b952408c8fe3a3801868f482ea355105fdd1bb7d9046daed13c41fa0ad33ef2462fd685df59b0abcf4ef4c791fd8c3514f9d346b0f3d9bb24873823fa0c6d1a2d4b87cb352450a8c0e28d391a1bbf3d265a91fa5b4e38697c489e80873a01aff5a406432dd5c40c8c3052a7fb095237fd45b7902b0c2a302e3217b7316e4a0babe839dcfe973b9079a1cc1f4ce5b1e11900f38d2cd929362feef7371ccc68ea0d3147164a9a973531fd97881ba09b61b5d8554c077017d738514c6fdeb24d746a0f73a86f932dc57b741bf274acf28fcbbf5b4d1324fb865cbc994b9528c008840a02b0781e32556190f4984d3a16037f3e9cfb06517c281fe3a088e1e52d1140f4ba02bfefe97f5815825308015a13728bc1ac875335470cc4bd60e5e3042bdd8c3c1a0d006ceb9404113ec501e23a64df09cb17581f838aafedc804ad4209ce72585f7a09cbbf0ac023bd73fec4007be7882b2ea0789ece1cf9700df96b8e47c307e75dca0b6813301fa1f36b66a38de4c82a9173d0792387c357a3f0f83097a13e073ecf9a07805ea2282d75ac1f1d725e270969fdd914b2e7fc547e2e55e9fea22cc8f9c0aa034728e7b747c378c00cd695b06abbade34356951572663128f1a23798cbd111480",
        "0xf90211a0004c0acd484e212a122f17957cd988029954ad77d42570cf2ad59de3618bf2f0a0f56520027628470394300d110ea71fc980418ba77339f07963650c3e3bb93f8ca0b14aaf9714e6582cebad7553628c838805f5d6f4895da02807e985aa2c0c05eda00084886b603e75c5b68d289e686d544c16015f14391ac67c3866298ef8e185c7a0b57387f2c6e33babaec7ca94092edcd1253e30f9fba23845a3da9958c2e2a650a0e331628e7b5bd61325eee083a9b6590415b410e9b70d825a5269111d54c17d1aa019e0df6d21514967dac884ba3389f5debb0ce700d97acd3c2001e9a5f1cda559a0db7aa29ccb9b543218ae4dda36138ad6d41627656455f2af0067a764bac9dd93a01a2987cd3969332362c69ad6fa9762e86b774a8097a6b9c288f59bdebc401f0fa008af05509e58d427ca5804cea75fdaa7ba9d5164f5dc5c0e88e4ad7f208e0aeaa04f552e99eb32ca1c9607b9a61c3e555ab026be9bdcde825c991bcd86117539f5a0605de34bb816f297ada6df25be75b448420c49ba0c96b05cf167b414d45f8436a0e8c92dd72effe9dc33a1b282c2189166ca69c181ada5d15820c0af33b26f3e34a081d4a26ab33ddf7e9a51dddc55e2c17c0cca1084aa651835af41854c20f8bf7ea0c90ed13b81924785c3e9703d97295712308e93c74c4651407b364f2549c92f48a076cf379abb59cd9bacb199c4dcd7b238c3d50cee96b94f55c52931a473fb38e280",
        "0xf90211a0f2ba598c570e8798d24e08021aff4f55f9290e0ff5a976b060e2cc4f53bff0aba0300850d631d25a0b26d63cec6e5d038a0393713cc11a435af83db30b39a5598ea07f2725054ec1dd0074ffdeaebca8e74674a2d76426aa38b7f007d3053cc51fc3a04c1e5e06929a93ba718a15e842bacb3fbe116f435c93dcda40c39f5675dce83aa0107c11e3890ab3b650734b7b9c77c012e07e355879e725a2fc6f800d8d2f8bd1a05a58d617dfa72c567019f846138779fd933cde75469fafb754ec45140daf2d36a0cf1f612594154988e734b55d580e0d45d194e90ddc2de38d4c0d13e18b70f5eba0d99702116d92bc205d02cf55f282f26160d6dc4d17aab716d4ca8114e218fbd7a01c44b63e798b4ac8eab4e7e731fb6206cca0d98db19c950d143aa190c900383ca0dea817be9a7cda4f9081d74ffb1c9499209ea49ad74536335a834331c75db27fa095cec64c39fa68bebd4b33108b6872913a44fd60b65c39ccbc05e58fd4e52053a06727f9fb8f22b59d3df54656e3c7fd063decc250774bb19c75d7e0b227e69f50a0b946cb857db5a3ce520c17e8873d3d4f83f5a6691ecb48cb9ec27c64992dcc67a0ec8cddfd0b5fa807682bbca84f7f3721990895cadae033d034b5aa9844e6abffa05cfe28037673edf4a8b80bb98ba7b6746b8809a7d1419c3b6713885202f8e20fa074a2ee502c435c5be8dd8577ac54570348419678ea166abb5f91533e801da8a180",
        "0xf90211a0ce7a291ddce8397f8f63ac786750ab2fa22a16ba983196ecadfd766398124177a04f94ae3d81086c6b82b03656a9d7472ce926eda44fef0b69db40d669022dac04a057256704039243d4d1d77caf1af266d1f3a09209f0347e5a60a475be4622f7cda030753cd6ba9dd7e1add6cafc346c98e51543e79e4c70554b9eb998a6a1ab557ba030be452625e368da08d06cde14b014b25f013a294bc585e0f0b1f6929e483880a0b024727783bba007507948216469e42230e9d8d576fd3c2f457bf6979490b798a05f44a193845f6f3054edab834215fae4370c0397c8637b329bf0beb21a98f5f3a036e852e5e0efeddaa97ff760d95dac31b83206f95bf008799c87f3f1495646f8a05affdc03e63ec3d9cf5928e50a8c5225cd3f8825bc91b58b144d712d52922f17a041e960472d324ee5f678e7c3ab87462f550718a9ca184aa13d4df31b650146a5a00a96b0015e7093a66c299831ad1e61f7af3f210f274bebe947b2aa9357d6130da0db87717a58064df97e5a1c7cdbd456e033836480a0b31a9b83c38101949cc80ea0ebf685dfa946b4380b03f2415324751dabda6fc787b170461d187f3b97490a13a0faf734dbc7370fda977b1ab644ecd53c15edefab484c41c39b9acc3bfe8782d6a0e64dfdee26409199d871e8a5b9f2ff79c6452fe122bd71b1838812c775b2b233a0e5e0444a27de63a509a8d34abcf59bac562c692c98418ccb76d62dd1c4ac544f80",
        "0xf90211a0c816e860406bd3838f115a76ed2b63461015cfa615803a326e8ee88e28319a6aa0eeea75868d0a44844b36d4ea52f3116a0ca9f4b5bef1817002589aca84601e88a04b469f97d839131ff4f315214c7341c79742b99b853697c2457d7d672ea7ee35a0ac20633a5c59df8f9fc56c1773f4b24da4722364c035fb875ec10041bfdaf834a0998be3dc46906fda5c475985e8044688b6fd803db65eeb1a09a1194610ff5535a0dc29bf8a7d43f845287d1f70798128a5cebd95a52672cc8d194f6d3959c7fbd8a05b13a91330a29682aa1a3cc1708613f06b5299cb78f77acef069271339cbda31a02f63613c79aee5d66db5f348409bd0bbc02559c6e6e7a26c7fd5a1a11b5cca37a02352b8a27762c7e29a33bd68ee43153c645decbbc136452893d1add1a12056d0a02cdad21b1a68a244706422b84746afe6fd40d5114973455dea9aee13a25a4c78a0a97940e89d61450b7813d01450086625635a240ac325751db0db2c7456d97e5ea05af6dd9a2f051e8f285d7d07eb46a2d93a160f59bdd045e0a7204f9536b4b6caa017348ad60aaa76e32ba16966f1bda7904eff93ca8acbe16803a9f3b1c3676778a04e323a8a7911d3c3d96d30862d0c25821a4a49be9a3986031f67bed41059b0c2a0777731fdfa2f6bda275a77e9adbfd6961b37c9f20f4c9dae4fd117112d26536ea0e0a9ff51acb87512bbba55ce6fdab79c3c863971aa4f3ea20d681a1a0aa6cead80",
        "0xf8d18080a0f7bdddcb784e46da481902edd84a390279b00dafba0e2b73d746c05b7a65419a80a067e58f2088b6191047566c1a3f7adedf907b52a8442c55b4ab6e219f04b948df80a059a65c5d8fda9b0e9c2ede9944f44daf7f0ce3c154fcd85070641d1465092935a0c92cd777f5286e8d03069736445d4971f4247310c1dbe3b3704498f3fee9b72980a0f6ea627d54cfa81277fbd4b91c8e4db1c7675de6b794a92f92c9d8c2c9d5d4fb80808080a0485f0776281b4ca272cedb99213dec485871c9b564b87409e3f1f5699fdc70518080",
        "0xf8518080808080808080a091cb3b47d7a9b5013d088fedbaeb63652e37d0275fc60f87fc64ec75528f052480808080a0a80db4935c79f722f522de51ef26f3a3dd51efb647df2e8dfa9b2f7e5f4b6849808080",
        "0xf86f9d20b44dda6f340ceb4818f25f1c7b9af7a9999bd3b3310c098a797468b7b84ff84d01890826795c9ec0430927a09c3b587f53fd236db0f47739a1110921aecf94e5efa4a3e863155367c52dc69ea03980451255e493e58008161f3645447b7f50756ea57a9af29b3dae54da936f0d",
        "0xf90131a0b7bfa9e9e1922a8843a6c0911c7f0c32b6358182f9ef4ce15afa608cd17b8aa280a04355bd3061ad2d17e0782413925b4fd81a56bd162d91eedb2a00d6c87611471480a032d86e91be3814148a0369285ec0ece9de33175fd9a392820d3468e2f5c024b1a0bce3ac16d022af7259a6ad050c947e69ada2ad6782750ce61952e30bf4c295bfa04197b89ad54a987dda73814a533282a3c35bcfec3189dfa1eb786186278084d280a002fd76ea858e1b63629886cca1ca2b9aceee51706d1f4a7a54a930b660e6874e80a0ccd65ebdc7c91831948e8f7cce14b51866b33741bdd94a36f0b1f30ae034e88180a023617b434423504384894b30421fa8a8ad666b45342072ba5eb5ab89f6db07f18080a03f0124180506a1ffa8838fe6fec56bf2e020a3e17e16ccacd2f0e0534f2aff3480",
        "0xe2a0390decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e56303"
    ]
  """

let wronRespType = 
  """
    {
      "foo": "Bar"
    }
  """

let wrongArrayElement = 
  """
    [ 
      7,
      "0xf90211a0fce2c4224ecaf51b69484308ea35568971b415218d7637d10f280e7677138e25a05022f349259d1c65ea252cc1d92cbd408642dfb3ae1cd683f06ce9a70b6cf906a09006bc304a486ed0ffe1464cc7c3d30a6c2e2ad68fac739c2d0705d64f462924a0b656d29eb22c930facd52cb8eb7b0d8555a957fc0921c121ead8fcb610c8ec9ca0f0a37daafaa3e11d2bc716bda5fa05d19051ed868562f2f95b533ad07a93922aa0b39178c732d92c088caafb3edf59b8c2386f51f9c0f0c2e6fd15ccd97370b212a0dd4c1127c8825a5d8e3ab8672dd924dbf8bc11c36d2fe8b1cff402fd1eef7293a08d38ad80852443b92b420d84ae60fc3a00e697c62a719de7a40ee82ae6cb38e4a09142b8354a0076b2e52a46813a4d45c46ed615d26c8c572fc314b7fb8c3fb01fa01e8c254927ac9b4bf215af1eb5cada70b3f482090d51ecd2b6d96d37b8eaa673a0cbfa5159bdcc0b01c8ef4f0a677a53a3d328f992906a2b655c054337174bdcdba0c7a8961f9ef3ea9204ee8ea3185bbd074efcca69263950bbea8ac4e80ece64caa0da1ad45521bb56ffcf8fca5e8608013cdeea432d7b1568713ad153a4fe320055a04615903adaff7e9eb3d40a0741317af48903bce60c01bf7c8400c75ab3651c21a044501873aa9131297b5c77f91d7a83ba845788b96b74d8c79edf0937964cc1d5a071eebceffcbcce68b6ad34111bdc8240d14d0de7eb167970ccb84fe2e4815bc480",
      "0xf90211a0bbba86270da1fbd2494b8422b9af95136d56ea41a9d832377348ad3d1984ee8ea0092e9d7e087e1af915cb3ff58541f70a566dd216603db8d68273537c8dfd4581a07d0d978774c613fe1952f997ff52f3fa660efef77ba05313744e71131d255a2ca01c034e63211f785b0b53f700e9d8861a3bc944336677544634945be33cb9378ca0333512e6b21cd35794bf53ec1f8f09803903bd2a9a0674be8ccfd563044275c9a0c1f240e6915bb06ffb9abad826d649e09ce1d7716895a274ec7d5b38f500b66fa0bec903e4d61bef1be9967d905a8bfd5120b532b81d10c3e52354a1f12592304ba0766f3b2c074dc2852dff6fd445638155546b483c5d7673471a772906dbc73784a019148d2973084180f8738eee2770526e5a85c3371df41e4404acd6a6cfa6592aa0a166be328bb46e1e2807c348a771a42f9296379af9c8da9e4a91c9d7a0067ceca0354f594ca3b5bc148d0d2206353a3ca87f089ba2ccb5378ee8407867d8729e84a02acd6b49c7eb7ee2754f7f93763eab704c88b108b9dba70e5c6536165f8e2ac3a0efde8ebfbfd5620a44ed084c419590a0c3851cf992c34a0aba8c8f3a51586befa08bbba2346f858f8d8db6ac71d56c5492dcb2d97794ef7c373df4060a6d43b96ba0843a5746bf11d7132a3aa1c923befe36a166ff1218d0724d8daa84311a15fc54a07a93c2c5a33cccf230060952c29071864c1a64d27a5c11789f998398e57bd0df80"
    ]
  """

suite "Bridge client parser suite":
  test "Parsing valid bridge_getBlockWitness response":
    let asJson = parseJson(validResponse)
    let parseResult = parseWitness(asJson)
    check parseResult.isOk()
    let sequenceResult = parseResult.get()
    check sequenceResult.len() == 19
  test "Parsing invalid bridge_getBlockWitness with wrong top type":
    let asJson = parseJson(wronRespType)
    let parseResult = parseWitness(asJson)
    check parseResult.isErr()
  test "Parsing invalid bridge_getBlockWitness with wrong array element":
    let asJson = parseJson(wrongArrayElement)
    let parseResult = parseWitness(asJson)
    check parseResult.isErr()
