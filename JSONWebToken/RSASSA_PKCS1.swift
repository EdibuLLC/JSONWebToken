//
//  RSASSA_PKCS1.swift
//  JSONWebToken
//
//  Created by Antoine Palazzolo on 18/11/15.
//

import Foundation
import Security

private func paddingForHashFunction(_ f : SignatureAlgorithm.HashFunction) -> SecPadding {
    switch f {
    case .sha256:
        return SecPadding.PKCS1SHA256
    case .sha384:
        return SecPadding.PKCS1SHA384
    case .sha512:
        return SecPadding.PKCS1SHA512
    }
}



public struct RSAKey {
    enum Error : Swift.Error {
        case securityError(OSStatus)
        case publicKeyNotFoundInCertificate
        case cannotCreateCertificateFromData
        case invalidP12ImportResult
        case invalidP12NoIdentityFound
    }
    let value : SecKey
        
    public init(secKey :SecKey) {
        self.value = secKey
    }
    public init(secCertificate cert: SecCertificate) throws {
        var trust : SecTrust? = nil
        let result = SecTrustCreateWithCertificates(cert, nil, &trust)
        if result == errSecSuccess && trust != nil {
            if let publicKey = SecTrustCopyPublicKey(trust!) {
                self.init(secKey : publicKey)
            } else {
                throw Error.publicKeyNotFoundInCertificate
            }
        } else {
            throw Error.securityError(result)
        }
    }
    //Creates a certificate object from a DER representation of a certificate.
    public init(certificateData data: Data) throws {
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            try self.init(secCertificate : cert)
        } else {
            throw Error.cannotCreateCertificateFromData
        }
    }
    
    public static func keysFromPkcs12Identity(_ p12Data : Data, passphrase : String) throws -> (publicKey : RSAKey, privateKey : RSAKey) {
        
        var importResult : CFArray? = nil
        let importParam = [kSecImportExportPassphrase as String: passphrase]
        let status = SecPKCS12Import(p12Data as CFData,importParam as CFDictionary, &importResult)
        
        guard status == errSecSuccess else { throw Error.securityError(status) }
        
        if let array = importResult.map({unsafeBitCast($0,to: NSArray.self)}),
            let content = array.firstObject as? NSDictionary,
            let identity = (content[kSecImportItemIdentity as String] as! SecIdentity?)
        {
            var privateKey : SecKey? = nil
            var certificate : SecCertificate? = nil
            let status = (
                SecIdentityCopyPrivateKey(identity, &privateKey),
                SecIdentityCopyCertificate(identity, &certificate)
            )
            guard status.0 == errSecSuccess else { throw Error.securityError(status.0) }
            guard status.1 == errSecSuccess else { throw Error.securityError(status.1) }
            if privateKey != nil && certificate != nil {
                return try (RSAKey(secCertificate: certificate!),RSAKey(secKey: privateKey!))
            } else {
                throw Error.invalidP12ImportResult
            }
        } else {
            throw Error.invalidP12NoIdentityFound
        }
    }
}

public struct RSAPKCS1Verifier : SignatureValidator {
    let hashFunction : SignatureAlgorithm.HashFunction
    let key : RSAKey
    
    public init(key : RSAKey, hashFunction : SignatureAlgorithm.HashFunction) {
        self.hashFunction = hashFunction
        self.key = key
    }
    public func canVerifyWithSignatureAlgorithm(_ alg : SignatureAlgorithm) -> Bool {
        if case SignatureAlgorithm.rsassa_PKCS1(self.hashFunction) = alg {
            return true
        }
        return false
    }
    public func verify(_ input : Data, signature : Data) -> Bool {
        let signedDataHash = (input as NSData).jwt_shaDigest(withSize: self.hashFunction.rawValue)
        let padding = paddingForHashFunction(self.hashFunction)
        

        let result: OSStatus = signature.withUnsafeBytes { (signatureRawPointer: UnsafeRawBufferPointer) in
            signedDataHash.withUnsafeBytes { (signedHashRawPointer: UnsafeRawBufferPointer) in

                guard let signtureAddress = signatureRawPointer.baseAddress, signatureRawPointer.count > 0,
                    let hashAddress = signedHashRawPointer.baseAddress, signedHashRawPointer.count > 0  else {

                    return -4 // OSStatus.errSecUnimplemented
                }

                return SecKeyRawVerify(
                    key.value,
                    padding,
                    signtureAddress.assumingMemoryBound(to: UInt8.self),
                    signedDataHash.count,
                    hashAddress.assumingMemoryBound(to: UInt8.self),
                    signature.count
                )
            }
        }
        
        switch result {
        case errSecSuccess:
            return true
        default:
            return false
        }
    }
}

public struct RSAPKCS1Signer : TokenSigner {
    enum Error : Swift.Error {
        case securityError(OSStatus)
    }
    
    let hashFunction : SignatureAlgorithm.HashFunction
    let key : RSAKey
    
    public init(hashFunction : SignatureAlgorithm.HashFunction, key : RSAKey) {
        self.hashFunction = hashFunction
        self.key = key
    }
    
    public var signatureAlgorithm : SignatureAlgorithm {
        return .rsassa_PKCS1(self.hashFunction)
    }

    public func sign(_ input : Data) throws -> Data {
        let signedDataHash = (input as NSData).jwt_shaDigest(withSize: self.hashFunction.rawValue)
        let padding = paddingForHashFunction(self.hashFunction)
        
        var result = Data(count: SecKeyGetBlockSize(self.key.value))
        var resultSize = result.count

        let status: OSStatus = result.withUnsafeMutableBytes { resultPointer in

            guard let pointer = resultPointer.baseAddress else { return -4 /* OSStatus.errSecUnimplemented */ }

            return SecKeyRawSign(key.value,
                                 padding,
                                 (signedDataHash as NSData).bytes.bindMemory(to: UInt8.self, capacity: signedDataHash.count),
                                 signedDataHash.count,
                                 UnsafeMutablePointer<UInt8>(pointer.assumingMemoryBound(to: UInt8.self)),
                                 &resultSize)

        }
        
        switch status {
        case errSecSuccess:
            return result.subdata(in: 0..<resultSize)
        default:
            throw Error.securityError(status)
        }
    }
}
