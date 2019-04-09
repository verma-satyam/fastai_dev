/*
THIS FILE WAS AUTOGENERATED! DO NOT EDIT!
file to edit: 04_callbacks.ipynb

*/
        
import Path
import TensorFlow

public struct BasicModel: Layer {
    public var layer1: Dense<Float>
    public var layer2: Dense<Float>
    
    public init(nIn: Int, nHid: Int, nOut: Int){
        layer1 = Dense(inputSize: nIn, outputSize: nHid, activation: relu)
        layer2 = Dense(inputSize: nHid, outputSize: nOut)
    }
    
    @differentiable
    public func applied(to input: Tensor<Float>, in context: Context) -> Tensor<Float> {
        return input.sequenced(in: context, through: layer1, layer2)
    }
}

public struct DataBunch<Element> where Element: TensorGroup{
    public var train: Dataset<Element>
    public var valid: Dataset<Element>
    
    public init(train: Dataset<Element>, valid: Dataset<Element>) {
        self.train = train
        self.valid = valid
    }
}

// TODO: When TF-421 is fixed, switch this back to Int32 labels.
public func mnistDataBunch(path: Path = mnistPath, flat: Bool = false, bs: Int = 64
                          ) -> DataBunch<DataBatch<Tensor<Float>, Tensor<Float>>>{
    let (xTrain,yTrain,xValid,yValid) = loadMNIST(path: path, flat: flat)
    let yTrain1: Tensor<Float> = Raw.oneHot(indices: yTrain, depth: Tensor(10), onValue: Tensor(1.0), offValue: Tensor(0.0))
    let yValid1: Tensor<Float> = Raw.oneHot(indices: yValid, depth: Tensor(10), onValue: Tensor(1.0), offValue: Tensor(0.0))
    return DataBunch(train: Dataset(elements:DataBatch(xb:xTrain, yb:yTrain1)).batched(Int64(bs)), 
                     valid: Dataset(elements:DataBatch(xb:xValid, yb:yValid1)).batched(Int64(bs)))
}

public enum LearnerAction: Error {
    case skipEpoch
    case skipBatch
    case stop
}

/// A model learner, responsible for initializing and training a model on a given dataset.
// NOTE: When TF-421 is fixed, make `Label` not constrained to `Differentiable`.
public final class Learner<Label: Differentiable & TensorGroup,
                           O: TensorFlow.Optimizer & AnyObject>
    where O.Scalar: Differentiable,
          // Constrain model input to Tensor<Float>, to work around
          // https://forums.fast.ai/t/fix-ad-crash-in-learner/42970.
          O.Model.Input == Tensor<Float>
{
    // Common type aliases.
    public typealias Input = Model.Input
    public typealias Data = DataBunch<DataBatch<Input, Label>>
    public typealias Loss = Tensor<Float>
    public typealias Optimizer = O
    public typealias Model = Optimizer.Model
    public typealias Variables = Model.AllDifferentiableVariables
    public typealias EventHandler = (Learner) throws -> Void
    
    /// A wrapper class to hold the loss function, to work around
    // https://forums.fast.ai/t/fix-ad-crash-in-learner/42970.
    public final class LossFunction {
        // NOTE: When TF-421 is fixed, replace with:
        //   public typealias F = @differentiable (Model.Output, @nondiff Label) -> Loss
        public typealias F = @differentiable (Model.Output, Label) -> Loss
        public var f: F
        init(_ f: @escaping F) { self.f = f }
    }
    
    /// The dataset on which the model will be trained.
    public var data: Data
    /// The optimizer used for updating model parameters along gradient vectors.
    public var optimizer: Optimizer
    /// The function that computes a loss value when given a prediction and a label.
    public var lossFunction: LossFunction
    /// The model being trained.
    public var model: Model
    
    //Is there a better way tonitiliaze those to not make them Optionals?
    public var currentInput: Input? = nil
    public var currentTarget: Label? = nil
    public var currentOutput: Model.Output? = nil
    
    /// The number of total epochs.
    public private(set) var epochCount: Int = .zero
    /// The current epoch.
    public private(set) var currentEpoch: Int = .zero
    /// The current gradient.
    public private(set) var currentGradient: Model.CotangentVector = .zero
    /// The current loss.
    public private(set) var currentLoss: Loss = .zero
    /// In training mode or not
    public private(set) var inTrain: Bool = false
    /// The current epoch + iteration, float between 0.0 and epochCount
    public private(set) var pctEpochs: Float = 0.0
    /// The current iteration
    public private(set) var currentIter: Int = 0
    /// The number of iterations in the current dataset
    public private(set) var iterCount: Int = 0
    
    open class Delegate {
        public init () {}
        
        open func trainingWillStart(learner: Learner) throws {}
        /// The completion of model training.
        open func trainingDidFinish(learner: Learner) throws {}
        /// A closure which will be called upon the start of an epoch.
        open func epochWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the completion of an epoch.
        open func epochDidFinish(learner: Learner) throws {}
        /// A closure which will be called upon the start of model validation.
        open func validationWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the start of training on a batch.
        open func batchWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the completion of training on a batch.
        open func batchDidFinish(learner: Learner) throws {}
        /// A closure which will be called when a new gradient has been computed.
        open func learnerDidProduceNewGradient(learner: Learner) throws {}
        /// A closure which will be called upon the completion of an optimizer update.
        open func optimizerDidUpdate(learner: Learner) throws {}
        
        /// TODO: learnerDidProduceNewOutput and learnerDidProduceNewLoss need to
        /// be differentiable once we can have the loss function inside the Learner
    }
    public var delegates: [Delegate] = []
    
    /// The context used for layer applications.
    public private(set) var context = Context(learningPhase: .training)

    /// Creates a learner.
    ///
    /// - Parameters:
    ///   - dataset: The dataset which will be trained on.
    ///   - lossFunction: The loss function.
    ///   - optimizer: The optimizer used for updating model parameters along
    ///     gradient vectors.
    ///   - modelInitializer: The closure that produces an model to be trained.
    ///
    public init(data: Data,
                lossFunction: @escaping LossFunction.F,
                optimizer: Optimizer,
                initializingWith modelInitializer: () -> Model) {
        self.data = data
        self.optimizer = optimizer
        self.lossFunction = LossFunction(lossFunction)
        self.model = modelInitializer()
    }
}

extension Learner {
    /// Trains the model on the given batch.
    ///
    /// - Parameter batch: The batch of input data and labels to be trained on.
    ///
    private func train(onBatch batch: DataBatch<Input, Label>) throws {
        (currentLoss, (currentGradient, _)) = model.valueWithGradient(at: batch.yb) { (model, yb) -> Loss in 
            let y = model.applied(to: batch.xb, in: context)
            currentOutput = y
            return lossFunction.f(y, yb)
        }
        try delegates.forEach { try $0.learnerDidProduceNewGradient(learner: self) }
        optimizer.update(&model.allDifferentiableVariables, along: self.currentGradient)
    }
    
    /// Performs a training epoch on a Dataset.
    private func train(onDataset ds: Dataset<DataBatch<Input, Label>>) throws {
        iterCount = ds.count(where: {_ in true})
        for batch in ds {
            (currentInput, currentTarget) = (batch.xb, batch.yb)
            try delegates.forEach { try $0.batchWillStart(learner: self) }
            do { try train(onBatch: batch) }
            catch LearnerAction.skipBatch { break }
            try delegates.forEach { try $0.batchDidFinish(learner: self) }
        }
    }
}

extension Learner{
    /// Starts fitting.
    /// - Parameter epochCount: The number of epochs that will be run.
    public func fit(_ epochCount: Int) throws {
        self.epochCount = epochCount
        do {
            try delegates.forEach { try $0.trainingWillStart(learner: self) }
            for i in 0..<epochCount {
                self.currentEpoch = i
                try delegates.forEach { try $0.epochWillStart(learner: self) }
                do { try train(onDataset: data.train) }
                try delegates.forEach { try $0.validationWillStart(learner: self) }
                do { try train(onDataset: data.valid) }
                catch LearnerAction.skipEpoch { break }
                try delegates.forEach { try $0.epochDidFinish(learner: self) }
            }
            try delegates.forEach { try $0.trainingDidFinish(learner: self) }
        } catch LearnerAction.stop { return }
    }
}

extension Learner {
    public class TrainEvalDelegate: Delegate {
        public override func trainingWillStart(learner: Learner) throws {
            learner.pctEpochs = 0.0
            learner.currentIter = 0
        }

        public override func epochWillStart(learner: Learner) throws {
            //print("Beginning epoch \(learner.currentEpoch)")
            learner.pctEpochs = Float(learner.currentEpoch)
            learner.context = Context(learningPhase: .training)
            learner.inTrain = true
        }
        
        public override func batchDidFinish(learner: Learner) throws{
            if learner.inTrain{
                learner.pctEpochs   += 1.0 / Float(learner.iterCount)
                learner.currentIter += 1
            }
        }
        
        public override func validationWillStart(learner: Learner) throws {
            learner.context = Context(learningPhase: .inference)
            learner.inTrain = false
        }
    }
}

extension Learner {
    public class AvgMetric: Delegate {
        public let metrics: [(Tensor<Float>, Tensor<Int32>) -> Tensor<Float>]
        var total: Int = 0
        var partials: [Tensor<Float>] = []
        
        public init(metrics: [(Tensor<Float>, Tensor<Int32>) -> Tensor<Float>]){ self.metrics = metrics}
        
        public override func epochWillStart(learner: Learner) throws {
            total = 0
            partials = Array(repeating: Tensor(0), count: metrics.count + 1)
        }
        
        public override func batchDidFinish(learner: Learner) throws{
            if !learner.inTrain{
                if let target = learner.currentTarget as? Tensor<Int32>{
                    let bs = target.shape[0]
                    total += Int(bs)
                    partials[0] += Float(bs) * learner.currentLoss
                    for i in 1...metrics.count{
                        partials[i] += Float(bs) * metrics[i-1]((learner.currentOutput as! Tensor<Float>), target)
                    }
                }
                
                // TODO: When TF-421 is fixed, remove this.
                if let target = learner.currentTarget as? Tensor<Float>{
                    let bs = target.shape[0]
                    total += Int(bs)
                    partials[0] += Float(bs) * learner.currentLoss
                }
            }
        }
        
        public override func epochDidFinish(learner: Learner) throws {
            for i in 0...metrics.count {partials[i] = partials[i] / Float(total)}
            print("Epoch \(learner.currentEpoch): \(partials)")
        }
    }
}
